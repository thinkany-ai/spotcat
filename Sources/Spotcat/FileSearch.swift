import AppKit

struct FileItem {
    let url: URL

    var name: String { FileManager.default.displayName(atPath: url.path) }
    var id: String { Self.idPrefix + url.path }

    static let idPrefix = "file:"

    /// 「最近使用」里的文件：已被删除或移动时返回 nil
    init?(id: String) {
        guard id.hasPrefix(Self.idPrefix) else { return nil }
        let path = String(id.dropFirst(Self.idPrefix.count))
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        url = URL(fileURLWithPath: path)
    }

    init(url: URL) {
        self.url = url
    }
}

/// 基于 Spotlight 索引（NSMetadataQuery）搜索用户目录下的文件和文件夹。
/// 结果异步返回；连续输入时只保留最后一次查询。
final class FileSearch {
    static let minimumQueryLength = 1
    /// 每批最多取这么多条参与本地排序
    private static let rankingWindow = 300
    /// 收集到这么多结果就停止，避免宽泛的词（如 "package"）遍历整个索引
    private static let gatherLimit = 1000
    private static let libraryPrefix = NSHomeDirectory() + "/Library/"

    /// 总是异步回调（在主线程）
    var onResults: ((_ query: String, _ files: [FileItem]) -> Void)?

    private let limit: Int
    private var query: NSMetadataQuery?
    private var queryText = ""
    private var observers: [NSObjectProtocol] = []
    private var debounce: DispatchWorkItem?
    /// 当前查询中带通配符的词，结果需在本地按完整模式再过滤
    private var globs: [String] = []

    init(limit: Int = 18) {
        self.limit = limit
    }

    func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        debounce?.cancel()
        // 太短时只停止查询，不回调：调用方只显示 query 与当前输入一致的结果，旧结果自然不会显示。
        // （在这里同步回调会与调用方的刷新形成递归）
        guard text.count >= Self.minimumQueryLength else {
            stop()
            queryText = text
            return
        }
        guard text != queryText || query == nil else { return }

        // 输入过程中稍等一下再发起查询，避免每个字符都启动一次 Spotlight 查询
        let work = DispatchWorkItem { [weak self] in self?.start(text) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func stop() {
        query?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query = nil
    }

    private func start(_ text: String) {
        stop()
        queryText = text

        // 每个词都要匹配文件名：普通词为「包含」，带 * ? 的词按整个文件名做通配符匹配
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\\", with: "") }
            .filter { !$0.isEmpty && $0 != "*" }
        guard !words.isEmpty else {
            onResults?(text, [])
            return
        }

        // Spotlight 的 * 只在模式开头/结尾有效（"douchat*.dmg" 查不到），
        // 所以把通配符词拆成若干前缀/后缀/包含条件交给 Spotlight，再在本地按完整模式精确过滤
        let predicates = words.flatMap { word in
            Glob.spotlightPatterns(for: word).map { NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, $0) }
        }
        globs = words.filter(Glob.hasWildcard)
        let excludeApps = NSPredicate(format: "NOT (%K == %@)", NSMetadataItemContentTypeKey, "com.apple.application-bundle")

        // 不让 Spotlight 排序（排序需要先收集全部结果），边收集边在本地排序显示
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates + [excludeApps])
        query.notificationBatchingInterval = 0.05

        let deliver: (Notification) -> Void = { [weak self, weak query] _ in
            guard let self, let query, query === self.query else { return }
            self.deliverResults(of: query, for: text)
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query, queue: .main, using: deliver),
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main, using: deliver),
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main, using: deliver),
        ]
        self.query = query
        query.start()
    }

    private func deliverResults(of query: NSMetadataQuery, for text: String) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        if query.resultCount >= Self.gatherLimit { query.stop() }

        // 排序：文件名与输入完全一致 → 以输入开头 → 其他；同级按最近使用时间
        let needle = text.lowercased()
        var ranked: [(file: FileItem, rank: Int, lastUsed: Date)] = []
        for index in 0..<min(query.resultCount, Self.rankingWindow) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            // 跳过隐藏目录、~/Library（缓存、日志等）和 node_modules，用户很少需要从启动器打开它们
            if path.contains("/.") || path.contains("/node_modules/") || path.hasPrefix(Self.libraryPrefix) { continue }

            let originalName = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? ""
            if !globs.allSatisfy({ Glob.matches(originalName, pattern: $0) }) { continue }
            let name = originalName.lowercased()
            let stem = (name as NSString).deletingPathExtension
            let rank = name == needle || stem == needle ? 0 : name.hasPrefix(needle) ? 1 : 2
            let lastUsed = item.value(forAttribute: "kMDItemLastUsedDate") as? Date ?? .distantPast
            ranked.append((FileItem(url: URL(fileURLWithPath: path)), rank, lastUsed))
        }
        ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.lastUsed > $1.lastUsed }
        let files = ranked.prefix(limit).map(\.file)
        onResults?(text, files)
    }
}

/// 文件名通配符：* 任意多个字符，? 单个字符，与 shell 一致按整个文件名匹配
enum Glob {
    static func hasWildcard(_ text: String) -> Bool {
        text.contains("*") || text.contains("?")
    }

    /// 交给 Spotlight 的 LIKE 模式（可能多个，需同时满足）。普通词为「包含」；
    /// 通配符词按 * 和 ? 拆段：首段为前缀、末段为后缀、中间段为包含——Spotlight 只支持两端的 *
    static func spotlightPatterns(for word: String) -> [String] {
        guard hasWildcard(word) else {
            // "douchat.dmg"：通常想找「名字含 douchat 的 dmg」（如 Douchat-0.1.6-mac-arm64.dmg），
            // 拆成「包含主干」+「以扩展名结尾」；完全同名的文件在排序时仍排最前
            let ext = (word as NSString).pathExtension
            let stem = (word as NSString).deletingPathExtension
            if !stem.isEmpty, FileQuery.isKnownExtension(ext) {
                return ["*\(stem)*", "*.\(ext)"]
            }
            return ["*\(word)*"]
        }
        let segments = word.replacingOccurrences(of: "?", with: "*")
            .split(separator: "*", omittingEmptySubsequences: false)
            .map(String.init)
        var patterns: [String] = []
        for (index, segment) in segments.enumerated() where !segment.isEmpty {
            let isFirst = index == 0
            let isLast = index == segments.count - 1
            switch (isFirst, isLast) {
            case (true, true): patterns.append(segment)
            case (true, false): patterns.append("\(segment)*")
            case (false, true): patterns.append("*\(segment)")
            case (false, false): patterns.append("*\(segment)*")
            }
        }
        return patterns
    }

    static func matches(_ name: String, pattern: String) -> Bool {
        NSPredicate(format: "SELF LIKE[cd] %@", pattern).evaluate(with: name)
    }
}

