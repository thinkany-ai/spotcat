import AppKit
import WebKit

/// 打开聊天的参数：来自扩展的 spotcat.chat.open，或搜索框里的「AI 对话」
struct ChatRequest {
    var title: String?
    /// 来源，如扩展名；显示在上下文标签上
    var source: String?
    /// 附带的上下文：[{ title, content }]，会作为系统提示的一部分发给模型
    var context: [[String: String]] = []
    /// 预填到输入框的内容
    var prompt: String?
    /// 为 true 时直接发送 prompt
    var send = false

    init(title: String? = nil, source: String? = nil, prompt: String? = nil, send: Bool = false) {
        self.title = title
        self.source = source
        self.prompt = prompt
        self.send = send
    }

    init(args: [String: Any], source: String?) {
        title = args["title"] as? String
        self.source = source
        context = (args["context"] as? [[String: Any]] ?? []).compactMap { item in
            guard let content = item["content"] as? String else { return nil }
            return ["title": item["title"] as? String ?? "", "content": content]
        }
        prompt = args["prompt"] as? String
        send = args["send"] as? Bool ?? false
    }

    var json: [String: Any] {
        [
            "title": title ?? NSNull(),
            "source": source ?? NSNull(),
            "context": context,
            "prompt": prompt ?? NSNull(),
            "send": send,
        ]
    }
}

/// Spotcat 内置的聊天面板。页面在 App 包的 Resources/chat 下，拥有全部 API 权限。
final class ChatView: NSView {
    var webView: WKWebView { bridge.webView }
    /// 返回上一级（扩展或搜索）
    var onBack: (() -> Void)?
    var onHide: (() -> Void)?
    var onDetach: (() -> Void)?
    /// 独立窗口的图钉控制置顶。
    var onPin: ((Bool) -> Void)?
    var onTitleChange: ((String) -> Void)?
    private(set) var title: String
    private var isDetached = false
    private var isPinned = false

    private let bridge: WebBridge
    private let agent = AgentRunner()
    private var agentTasks: [Int: Task<Void, Never>] = [:]
    private let api = ExtensionAPI(storageID: "spotcat.chat", permissions: nil)

    static var directory: URL? {
        if let root = AppEnvironment.sourceRoot {
            return root.appendingPathComponent("Resources/chat", isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("chat", isDirectory: true)
    }

    init?(request: ChatRequest) {
        guard let directory = Self.directory else { return nil }
        let l10n = LocaleMessages(directory: directory, defaultLocale: "en")
        var data = request.json
        title = request.title ?? L10n.t("chat.title")
        data["profile"] = ["name": SettingsStore.shared.nickname.trimmingCharacters(in: .whitespaces)]
        bridge = WebBridge(context: [
            "enter": ["code": "chat", "type": "open", "payload": request.prompt ?? "", "data": data],
            "i18n": ["locale": l10n.locale, "messages": l10n.messages],
        ])
        super.init(frame: .zero)

        api.emit = { [weak self] event, payload in self?.bridge.emit(event, payload) }
        bridge.handler = { [weak self] method, args, reply in
            self?.handle(method: method, args: args, reply: reply) ?? false
        }
        bridge.webView.autoresizingMask = [.width, .height]
        addSubview(bridge.webView)
        bridge.load(directory.appendingPathComponent("index.html"), readAccess: directory)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func setWindowState(detached: Bool, pinned: Bool) {
        isDetached = detached
        isPinned = pinned
        bridge.emit("window.state", ["detached": detached, "pinned": pinned])
    }

    /// Esc 先交给页面（如关闭历史列表），页面没处理时再执行 fallback（返回上一级）
    func handleEscape(fallback: @escaping () -> Void) {
        webView.evaluateJavaScript("window.__spotcatEscape?.() === true") { result, _ in
            if (result as? Bool) != true { fallback() }
        }
    }

    func teardown() {
        agentTasks.values.forEach { $0.cancel() }
        api.teardown()
        bridge.teardown()
    }

    private func handle(method: String, args: [String: Any], reply: @escaping WebBridge.Reply) -> Bool {
        switch method {
        case "copyText":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(args["text"] as? String ?? "", forType: .string)
            reply(true, nil)
        case "hideWindow":
            reply(true, nil)
            onHide?()
        case "exit":
            reply(true, nil)
            onBack?()
        case "window.pin":
            guard isDetached else { reply(false, nil); break }
            isPinned = args["pinned"] as? Bool ?? false
            reply(true, nil)
            onPin?(isPinned)
        case "window.detach":
            reply(true, nil)
            onDetach?()
        case "window.state":
            reply(["detached": isDetached, "pinned": isPinned], nil)
        case "window.title":
            if let title = args["title"] as? String, !title.isEmpty {
                self.title = title
                onTitleChange?(title)
            }
            reply(true, nil)
        case "agent.chat":
            runAgent(args, reply: reply)
        case "agent.cancel":
            if let id = (args["id"] as? NSNumber)?.intValue { agentTasks[id]?.cancel() }
            reply(true, nil)
        case "models.pick":
            pickModel(args, reply: reply)
        case "attachments.pick":
            ChatAttachments.pick(in: window, limit: (args["limit"] as? Int) ?? 4, reply: reply)
        case "history.list":
            reply(ChatHistory.list(), nil)
        case "history.get":
            reply(ChatHistory.get(id: args["id"] as? String ?? ""), nil)
        case "history.save":
            guard let chat = args["chat"] as? [String: Any] else { reply(nil, "history.save 需要 chat"); break }
            do {
                try ChatHistory.save(chat)
                reply(true, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        case "history.delete":
            ChatHistory.delete(id: args["id"] as? String ?? "")
            reply(true, nil)
        default:
            return api.handle(method: method, args: args, reply: reply)
        }
        return true
    }

    // MARK: - Agent

    /// 运行一次带工具的回复。过程通过 "agent.event" 推给页面，结束时返回本次新增的消息（页面存进历史）
    private func runAgent(_ args: [String: Any], reply: @escaping WebBridge.Reply) {
        guard let id = (args["id"] as? NSNumber)?.intValue else { return reply(nil, "agent.chat requires id") }
        let messages = args["messages"] as? [[String: Any]] ?? []
        let model = args["model"] as? String
        agentTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let added = try await self.agent.run(messages: messages, model: model) { [weak self] event in
                    var event = event
                    event["id"] = id
                    self?.bridge.emit("agent.event", event)
                }
                reply(["messages": added], nil)
            } catch is CancellationError {
                reply(nil, "Cancelled")
            } catch let error as URLError where error.code == .cancelled {
                reply(nil, "Cancelled")
            } catch {
                reply(nil, error.localizedDescription)
            }
            self.agentTasks[id] = nil
        }
    }

    // MARK: - 切换模型

    /// 在页面给的位置（按钮左下角，页面坐标）弹出原生菜单：服务商 › 模型。返回选中的 "服务商 id/模型名"，取消时为 nil
    private func pickModel(_ args: [String: Any], reply: @escaping WebBridge.Reply) {
        let config = SettingsStore.shared.models
        let current = config.resolve(args["current"] as? String).map { "\($0.provider.id)/\($0.model)" }
        let picker = ModelMenuTarget()
        let menu = NSMenu()
        menu.autoenablesItems = false

        for provider in config.providers where !provider.models.isEmpty {
            let item = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for model in provider.models {
                let id = "\(provider.id)/\(model)"
                let modelItem = NSMenuItem(title: model, action: #selector(ModelMenuTarget.pick(_:)), keyEquivalent: "")
                modelItem.target = picker
                modelItem.representedObject = id
                modelItem.state = id == current ? .on : .off
                modelItem.isEnabled = provider.hasKey
                submenu.addItem(modelItem)
            }
            item.submenu = submenu
            if current?.hasPrefix(provider.id + "/") == true { item.state = .on }
            if !provider.hasKey {
                item.title = provider.name + " — " + L10n.t("chat.model.noKey")
            }
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let manage = NSMenuItem(title: L10n.t("chat.model.manage"), action: #selector(ModelMenuTarget.manage(_:)), keyEquivalent: "")
        manage.target = picker
        menu.addItem(manage)

        let x = (args["x"] as? Double) ?? 0
        let y = (args["y"] as? Double) ?? 0
        let point = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        menu.popUp(positioning: args["above"] as? Bool == true ? menu.items.last : nil, at: point, in: webView)

        switch picker.result {
        case .model(let id): reply(id, nil)
        case .manage:
            reply(nil, nil)
            (NSApp.delegate as? AppDelegate)?.showSettings(tab: .ai)
        case nil: reply(nil, nil)
        }
    }
}

/// NSMenu 的 action 需要一个 NSObject target；popUp 返回前 action 已经执行，结果存在这里
private final class ModelMenuTarget: NSObject {
    enum Result { case model(String), manage }
    var result: Result?

    @objc func pick(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { result = .model(id) }
    }

    @objc func manage(_ sender: NSMenuItem) {
        result = .manage
    }
}
