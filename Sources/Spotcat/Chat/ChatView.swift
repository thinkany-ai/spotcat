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

    private let bridge: WebBridge
    private let api = ExtensionAPI(storageID: "spotcat.chat", permissions: nil)

    static var directory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("chat", isDirectory: true)
    }

    init?(request: ChatRequest) {
        guard let directory = Self.directory else { return nil }
        let l10n = LocaleMessages(directory: directory, defaultLocale: "en")
        var data = request.json
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

    func teardown() {
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
        default:
            return api.handle(method: method, args: args, reply: reply)
        }
        return true
    }
}
