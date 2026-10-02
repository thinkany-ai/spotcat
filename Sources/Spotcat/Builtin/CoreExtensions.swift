import AppKit

/// Spotcat 自身的指令：设置、扩展。不能停用，否则没有入口改回来
final class SpotcatCommandsExtension: BuiltinExtension {
    let id = "builtin.spotcat"
    var name: String { "Spotcat" }
    var description: String { L10n.t("builtin.spotcat.description") }
    let icon: (symbol: String, color: NSColor) = ("gearshape.fill", .systemGray)
    let canDisable = false

    private let commands: [BuiltinCommand] = [.settings, .extensions]

    func items(query: String) -> [LauncherItem] {
        commands.map { .command($0) }
    }

    func item(forID id: String) -> LauncherItem? {
        commands.first { $0.id == id }.map { .command($0) }
    }
}

/// 内置 AI 对话：关键词进入，或把任意输入直接拿去问 AI
final class ChatExtension: BuiltinExtension {
    let id = "builtin.chat"
    var name: String { L10n.t("chat.itemTitle") }
    var description: String { L10n.t("builtin.chat.description") }
    var icon: (symbol: String, color: NSColor) { ("bubble.left.and.bubble.right.fill", Theme.accentNSColor) }

    func items(query: String) -> [LauncherItem] {
        [.chat(trigger: LauncherItem.chatKeyword(query) ? .keyword : .match)]
    }

    /// 任意文本都可以直接问 AI，放在匹配推荐的第一位
    func suggestions(for text: String) -> [LauncherItem] {
        [.chat(trigger: .match)]
    }

    func item(forID id: String) -> LauncherItem? {
        id == LauncherItem.chatID ? .chat(trigger: .keyword) : nil
    }
}

/// 文件搜索："file: xxx" 用 Spotlight 搜文件，输入像文件名/路径时提示进入
final class FilesExtension: BuiltinExtension {
    let id = "builtin.files"
    var name: String { L10n.t("command.searchFiles") }
    var description: String { L10n.t("builtin.files.description") }
    var icon: (symbol: String, color: NSColor) { BuiltinCommand.searchFiles.icon }

    func items(query: String) -> [LauncherItem] {
        [.command(.searchFiles)]
    }

    func pinnedItems(for text: String) -> [LauncherItem] {
        WebAddress.url(from: text) == nil && FileQuery.looksLikeFile(text) ? [.searchFiles(text)] : []
    }

    func item(forID id: String) -> LauncherItem? {
        id == BuiltinCommand.searchFiles.id ? .command(.searchFiles) : nil
    }
}

/// 快捷链接和网页搜索：输入网址直接打开，「关键词 内容」用对应网站搜索，任意输入可用默认搜索引擎搜索
final class QuicklinksExtension: BuiltinExtension {
    let id = "builtin.quicklinks"
    var name: String { L10n.t("builtin.quicklinks.name") }
    var description: String { L10n.t("builtin.quicklinks.description") }
    let icon: (symbol: String, color: NSColor) = ("globe", .systemTeal)

    func items(query: String) -> [LauncherItem] {
        SettingsStore.shared.quicklinks.map { .quicklink($0, query: nil) }
    }

    func pinnedItems(for text: String) -> [LauncherItem] {
        var items: [LauncherItem] = []
        if let url = WebAddress.url(from: text) {
            items.append(.url(url))
        }
        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        if let first = parts.first?.lowercased(),
           let link = SettingsStore.shared.quicklinks.first(where: { !$0.keyword.isEmpty && $0.keyword.lowercased() == first }) {
            let query = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
            if query == nil || link.acceptsQuery {
                items.append(.quicklink(link, query: query))
            }
        }
        return items
    }

    /// 用默认搜索引擎搜索整段输入（输入本身是网址、文件名或快捷链接时由调用方去掉）
    func suggestions(for text: String) -> [LauncherItem] {
        SettingsStore.shared.searchEngine.map { [.webSearch($0, query: text)] } ?? []
    }

    func item(forID id: String) -> LauncherItem? {
        if id.hasPrefix("url:"), let url = URL(string: String(id.dropFirst(4))) { return .url(url) }
        guard id.hasPrefix("quicklink:") else { return nil }
        let linkID = String(id.dropFirst("quicklink:".count))
        return SettingsStore.shared.quicklinks.first { $0.id == linkID }.map { .quicklink($0, query: nil) }
    }
}
