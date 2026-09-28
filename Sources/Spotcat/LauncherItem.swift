import AppKit

/// Spotcat 自身的指令，和应用、扩展一起出现在搜索结果里
enum BuiltinCommand: String, CaseIterable {
    case settings
    case searchFiles

    var id: String { "builtin:\(rawValue)" }

    var title: String {
        switch self {
        case .settings: return L10n.t("command.settings")
        case .searchFiles: return L10n.t("command.searchFiles")
        }
    }

    /// 中英文关键词都能搜到
    var searchKeys: [String] {
        switch self {
        case .settings:
            return ["Spotcat 设置", "Spotcat Settings", "设置", "偏好设置", "settings", "preferences", "config"]
                .flatMap(SearchText.keys(for:))
        case .searchFiles:
            return ["搜索文件", "Search Files", "文件", "file", "files", "find", "finder"]
                .flatMap(SearchText.keys(for:))
        }
    }

    var icon: (symbol: String, color: NSColor) {
        switch self {
        case .settings: return ("gearshape.fill", .systemGray)
        case .searchFiles: return ("folder.fill", .systemBlue)
        }
    }
}

/// 搜索结果里的一个格子：本地应用、某个扩展的某个功能、内置的 AI 对话或内置指令
enum LauncherItem {
    case app(AppItem)
    case feature(ExtensionFeatureRef, trigger: EnterTrigger)
    case chat(trigger: EnterTrigger)
    case command(BuiltinCommand)
    case file(FileItem)
    /// 输入本身就是网址
    case url(URL)
    /// 快捷链接；query 为关键词后面的内容
    case quicklink(Quicklink, query: String?)
    /// 用默认搜索引擎搜索整段输入（出现在匹配推荐里）
    case webSearch(Quicklink, query: String)
    /// 输入像文件名/路径时的「搜索文件：xxx」，进入 file: 模式
    case searchFiles(String)

    static let chatID = "builtin:chat"
    /// 中英文关键词都能搜到 AI 对话
    static let chatKeywords = ["AI 对话", "Ask AI", "ai", "chat", "ask", "对话", "提问"].flatMap(SearchText.keys(for:))

    /// 悬停提示：文件显示完整路径
    var toolTip: String? {
        switch self {
        case .file(let file): return (file.url.path as NSString).abbreviatingWithTildeInPath
        case .app(let app): return (app.url.path as NSString).abbreviatingWithTildeInPath
        case .url(let url): return url.absoluteString
        case .quicklink(let link, let query): return link.resolvedURL(query: query)?.absoluteString
        case .webSearch(let link, let query): return link.resolvedURL(query: query)?.absoluteString
        default: return nil
        }
    }

    /// 可在访达中显示的位置
    var fileURL: URL? {
        switch self {
        case .file(let file): return file.url
        case .app(let app): return app.url
        default: return nil
        }
    }

    static func chatKeyword(_ query: String) -> Bool {
        !query.isEmpty && chatKeywords.contains { $0.lowercased().filter { !$0.isWhitespace }.hasPrefix(query) }
    }

    var id: String {
        switch self {
        case .app(let app): return app.url.path
        case .feature(let ref, _): return ref.id
        case .chat: return Self.chatID
        case .command(let command): return command.id
        case .file(let file): return file.id
        case .url(let url): return "url:" + url.absoluteString
        case .quicklink(let link, _): return "quicklink:" + link.id
        case .webSearch(let link, _): return "websearch:" + link.id
        case .searchFiles: return "builtin:searchFilesFor"
        }
    }

    var name: String {
        switch self {
        case .app(let app): return app.name
        case .feature(let ref, _): return ref.feature.title
        case .chat: return L10n.t("chat.itemTitle")
        case .command(let command): return command.title
        case .file(let file): return file.name
        case .url(let url): return L10n.t("web.open", WebAddress.display(url))
        case .quicklink(let link, let query):
            guard let query, !query.isEmpty, link.acceptsQuery else { return link.name }
            return L10n.t("web.search", link.name, query)
        case .webSearch(let link, _): return L10n.t("web.searchWith", link.name)
        case .searchFiles(let term):
            return L10n.t(PathQuery.isPath(term) ? "files.browse" : "files.searchFor", term)
        }
    }

    var searchKeys: [String] {
        switch self {
        case .app(let app): return app.searchKeys
        case .feature(let ref, _): return ref.searchKeys
        case .chat: return Self.chatKeywords
        case .command(let command): return command.searchKeys
        // 文件由 Spotlight 匹配，网址和带查询词的快捷链接由输入直接生成，不参与本地模糊搜索
        case .file, .url, .webSearch, .searchFiles: return []
        case .quicklink(let link, _): return SearchText.keys(for: link.name) + [link.keyword]
        }
    }
}
