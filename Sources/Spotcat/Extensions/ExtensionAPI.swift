import AppKit
import AVFAudio
import NaturalLanguage
import Translation

/// window.spotcat 中需要原生实现的能力。每个页面一个实例，reply 必须在主线程调用。
final class ExtensionAPI {
    typealias Reply = (Any?, String?) -> Void

    /// nil 表示拥有全部权限（Spotcat 内置面板）
    private let permissions: Set<String>?
    private let storage: ExtensionStorage
    /// 网页扩展的 id 和第一个功能，spotcat.search.setItems 使用；内置聊天面板没有
    private let searchScope: (extensionID: String, defaultCode: String)?
    /// 向页面推送事件，由宿主设置
    var emit: ((String, Any) -> Void)?
    private var aiTasks: [Int: Task<Void, Never>] = [:]
    private var clipboardObserver: NSObjectProtocol?

    init(storageID: String, permissions: Set<String>?, searchScope: (extensionID: String, defaultCode: String)? = nil) {
        self.permissions = permissions
        self.searchScope = searchScope
        storage = ExtensionStorage(extensionID: storageID)
    }

    convenience init(ext: SpotcatExtension) {
        self.init(storageID: ext.id, permissions: Set(ext.manifest.permissions ?? []),
                  searchScope: ext.manifest.features.first.map { (ext.id, $0.code) })
    }

    func isGranted(_ permission: ExtensionPermission) -> Bool {
        permissions?.contains(permission.rawValue) ?? true
    }

    func teardown() {
        if let clipboardObserver { NotificationCenter.default.removeObserver(clipboardObserver) }
        clipboardObserver = nil
        aiTasks.values.forEach { $0.cancel() }
        aiTasks.removeAll()
        Speaker.shared.stop()
    }

    /// 返回 false 表示不是这里处理的方法
    func handle(method: String, args: [String: Any], reply: @escaping Reply) -> Bool {
        switch method {
        case "storage.get":
            reply(storage.get(args["key"] as? String ?? ""), nil)
        case "storage.set":
            guard let key = args["key"] as? String else { reply(nil, "storage.set 需要 key"); break }
            do {
                try storage.set(key, value: args["value"])
                reply(true, nil)
            } catch {
                reply(nil, "保存失败：\(error.localizedDescription)")
            }
        case "storage.remove":
            try? storage.set(args["key"] as? String ?? "", value: nil)
            reply(true, nil)
        case "search.setItems":
            setSearchItems(args, reply: reply)
        case let method where method.hasPrefix("clipboard."):
            clipboard(method, args, reply: reply)
        case "fetch":
            fetch(args, reply: reply)
        case "detectLanguage":
            reply(Self.detectLanguage(args["text"] as? String ?? ""), nil)
        case "speak":
            Speaker.shared.speak(args["text"] as? String ?? "", language: args["lang"] as? String)
            reply(true, nil)
        case "stopSpeaking":
            Speaker.shared.stop()
            reply(true, nil)
        case "translate":
            translate(args, reply: reply)
        case "openURL":
            openURL(args["url"] as? String, reply: reply)
        case "openSettings":
            let tab = (args["tab"] as? String).flatMap(SettingsTab.init(rawValue:))
            (NSApp.delegate as? AppDelegate)?.showSettings(tab: tab)
            reply(true, nil)
        case "ai.info":
            let target = SettingsStore.shared.models.resolve(args["model"] as? String)
            reply([
                "configured": target?.provider.hasKey ?? false,
                "id": target.map { "\($0.provider.id)/\($0.model)" } ?? "",
                "model": target?.model ?? "",
                "provider": target?.provider.name ?? "",
            ], nil)
        case "ai.chat":
            aiChat(args, reply: reply)
        case "ai.cancel":
            if let id = (args["id"] as? NSNumber)?.intValue { aiTasks[id]?.cancel() }
            reply(true, nil)
        default:
            return false
        }
        return true
    }

    // MARK: - 剪贴板历史

    /// clipboard.paste 需要隐藏面板，由宿主（ExtensionHostView）处理；这里只负责数据
    private func clipboard(_ method: String, _ args: [String: Any], reply: Reply) {
        guard isGranted(.clipboard) else { return reply(nil, L10n.t("error.permission", "clipboard")) }
        let history = ClipboardHistory.shared
        let id = args["id"] as? String ?? ""
        switch method {
        case "clipboard.list":
            let query = (args["query"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            let limit = (args["limit"] as? NSNumber)?.intValue ?? 200
            let matched = history.entries.filter { entry in
                guard !query.isEmpty else { return true }
                let haystack = [entry.text, entry.files?.joined(separator: "\n"), entry.app].compactMap { $0 }.joined(separator: "\n")
                return haystack.lowercased().contains(query)
            }
            // 置顶的在前，其余按时间
            let sorted = matched.filter(\.pinned) + matched.filter { !$0.pinned }
            reply(sorted.prefix(max(0, limit)).map(Self.describe), nil)
        case "clipboard.get":
            guard let entry = history.entry(id: id) else { return reply(nil, "No clipboard item \(id)") }
            var item = Self.describe(entry)
            item["text"] = entry.text
            item["image"] = history.thumbnail(for: entry)
            reply(item, nil)
        case "clipboard.thumbnail":
            reply(history.entry(id: id).flatMap { history.thumbnail(for: $0, maxSize: 96) }, nil)
        case "clipboard.copy":
            reply(history.copy(id: id), nil)
        case "clipboard.pin":
            history.setPinned(args["pinned"] as? Bool ?? true, id: id)
            reply(true, nil)
        case "clipboard.remove":
            history.remove(id: id)
            reply(true, nil)
        case "clipboard.clear":
            history.clear()
            reply(true, nil)
        case "clipboard.status":
            reply(["recording": history.isActive], nil)
        case "clipboard.watch":
            // 记录到新内容时推送 clipboard.change 事件
            if clipboardObserver == nil {
                clipboardObserver = NotificationCenter.default.addObserver(forName: ClipboardHistory.didChange, object: nil, queue: .main) { [weak self] _ in
                    self?.emit?("clipboard.change", [:])
                }
            }
            reply(true, nil)
        default:
            reply(nil, "Unknown method \(method)")
        }
    }

    /// 列表用的摘要：文本只给前 300 字，图片不带数据（另取缩略图）
    private static func describe(_ entry: ClipboardHistory.Entry) -> [String: Any] {
        var item: [String: Any] = [
            "id": entry.id,
            "type": entry.kind.rawValue,
            "time": Int(entry.date.timeIntervalSince1970 * 1000),
            "pinned": entry.pinned,
        ]
        if let text = entry.text {
            item["preview"] = String(text.prefix(300))
            item["length"] = text.count
        }
        if let files = entry.files { item["files"] = files }
        if let width = entry.imageWidth, let height = entry.imageHeight { item["size"] = [width, height] }
        if let app = entry.app { item["app"] = app }
        return item
    }

    // MARK: - 搜索

    /// 把扩展的内容交给 Spotcat 搜索；整体替换，传空数组清除
    private func setSearchItems(_ args: [String: Any], reply: Reply) {
        guard let scope = searchScope else { return reply(nil, "search.setItems is only available to extensions") }
        guard let raw = args["items"] as? [[String: Any]] else { return reply(nil, "search.setItems requires an array of items") }
        guard raw.count <= ExtensionSearchIndex.maxItems else {
            return reply(nil, "search.setItems accepts at most \(ExtensionSearchIndex.maxItems) items")
        }
        let clip = { (value: Any?, limit: Int) -> String? in (value as? String).map { String($0.prefix(limit)) } }
        var items: [ExtensionSearchIndex.Item] = []
        for item in raw {
            guard let id = item["id"] as? String ?? (item["id"] as? NSNumber)?.stringValue,
                  let title = clip(item["title"], 200), !title.isEmpty else {
                return reply(nil, "Each item needs an id and a non-empty title")
            }
            items.append(ExtensionSearchIndex.Item(
                id: id,
                code: item["code"] as? String ?? scope.defaultCode,
                title: title,
                subtitle: clip(item["subtitle"], 300),
                text: clip(item["text"], 5000)
            ))
        }
        do {
            try ExtensionSearchIndex.shared.setItems(items, extensionID: scope.extensionID)
            reply(true, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    // MARK: - fetch

    /// 由 App 代发请求，不受页面 CORS 限制；需要在 manifest 声明 "network" 权限
    private func fetch(_ args: [String: Any], reply: @escaping Reply) {
        guard isGranted(.network) else {
            return reply(nil, L10n.t("error.permission", "network"))
        }
        guard let urlString = args["url"] as? String, let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http" else {
            return reply(nil, "无效的 URL")
        }

        var request = URLRequest(url: url, timeoutInterval: (args["timeout"] as? Double).map { $0 / 1000 } ?? 30)
        request.httpMethod = (args["method"] as? String)?.uppercased() ?? "GET"
        for (name, value) in args["headers"] as? [String: String] ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = args["body"] as? String {
            request.httpBody = Data(body.utf8)
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error { return reply(nil, error.localizedDescription) }
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (name, value) in http?.allHeaderFields ?? [:] {
                    headers[String(describing: name).lowercased()] = String(describing: value)
                }
                reply([
                    "status": http?.statusCode ?? 0,
                    "headers": headers,
                    "body": data.flatMap { String(data: $0, encoding: .utf8) } ?? "",
                ], nil)
            }
        }.resume()
    }

    // MARK: - AI

    /// 使用 Spotcat 设置中的 AI 服务；stream 为 true 时通过 "ai.delta" 事件推送增量
    private func aiChat(_ args: [String: Any], reply: @escaping Reply) {
        guard isGranted(.ai) else { return reply(nil, L10n.t("error.permission", "ai")) }
        guard let id = (args["id"] as? NSNumber)?.intValue else { return reply(nil, "ai.chat requires id") }
        let messages: [[String: String]] = (args["messages"] as? [[String: Any]] ?? []).compactMap { message in
            guard let role = message["role"] as? String, let content = message["content"] as? String else { return nil }
            return ["role": role, "content": content]
        }
        let stream = args["stream"] as? Bool ?? false
        let model = args["model"] as? String

        aiTasks[id] = Task { @MainActor [weak self] in
            do {
                let text = try await AIService.shared.chat(messages: messages, model: model, onDelta: stream ? { delta in
                    self?.emit?("ai.delta", ["id": id, "delta": delta])
                } : nil)
                reply(text, nil)
            } catch is CancellationError {
                reply(nil, "Cancelled")
            } catch let error as URLError where error.code == .cancelled {
                reply(nil, "Cancelled")
            } catch {
                reply(nil, error.localizedDescription)
            }
            self?.aiTasks[id] = nil
        }
    }

    // MARK: - 语言

    /// 返回 BCP-47 语言代码，如 "en"、"zh-Hans"、"ja"；无法识别时返回 nil
    static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// 系统翻译（Translation 框架，离线，需要对应的语言包已下载）
    private func translate(_ args: [String: Any], reply: @escaping Reply) {
        guard let text = args["text"] as? String, !text.isEmpty else { return reply(nil, "text 不能为空") }
        guard let target = args["to"] as? String else { return reply(nil, "需要 to 参数") }
        guard let source = (args["from"] as? String).flatMap({ $0 == "auto" ? nil : $0 }) ?? Self.detectLanguage(text) else {
            return reply(nil, L10n.t("error.translate.unknownSource"))
        }
        guard #available(macOS 26.0, *) else {
            return reply(nil, L10n.t("error.translate.requiresOS"))
        }

        Task { @MainActor in
            let from = Locale.Language(identifier: source)
            let to = Locale.Language(identifier: target)
            do {
                let session = TranslationSession(installedSource: from, target: to)
                let response = try await session.translate(text)
                reply(["text": response.targetText, "from": source, "to": target], nil)
            } catch {
                let status = await LanguageAvailability().status(from: from, to: to)
                switch status {
                case .supported:
                    let displayLocale = Locale(identifier: L10n.language)
                    let name = { (code: String) in displayLocale.localizedString(forIdentifier: code) ?? code }
                    reply(nil, L10n.t("error.translate.missingPack", name(source), name(target)))
                case .unsupported:
                    reply(nil, L10n.t("error.translate.unsupported"))
                default:
                    reply(nil, error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 其他

    /// 只允许打开网页和系统设置
    private func openURL(_ string: String?, reply: Reply) {
        guard let string, let url = URL(string: string),
              ["http", "https", "x-apple.systempreferences"].contains(url.scheme ?? "") else {
            return reply(nil, "不支持的 URL")
        }
        NSWorkspace.shared.open(url)
        reply(true, nil)
    }
}

/// 每个扩展一个 JSON 文件：~/Library/Application Support/Spotcat/ExtensionData/<id>.json
final class ExtensionStorage {
    private let url: URL
    private var values: [String: Any]

    init(extensionID: String) {
        let dir = AppEnvironment.dataDirectory.appendingPathComponent("ExtensionData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(extensionID).json")
        values = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    func get(_ key: String) -> Any? {
        values[key]
    }

    /// value 为 nil（或 JS 的 null/undefined）时删除
    func set(_ key: String, value: Any?) throws {
        if let value, !(value is NSNull) {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

final class Speaker {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, language: String?) {
        stop()
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        // 语音用 zh-CN / zh-TW，语言识别给出的是 zh-Hans / zh-Hant
        let lang = (language ?? ExtensionAPI.detectLanguage(text)).map { ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][$0] ?? $0 }
        if let lang, let voice = AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: String(lang.prefix(2))) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}
