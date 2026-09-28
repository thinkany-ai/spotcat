import AppKit

/// "file: xxx" 形式的查询
enum FileQuery {
    private static let prefixes = ["file:", "file：", "文件:", "文件："]

    /// 以前缀开头时返回要搜索的文件名（可能为空），否则返回 nil
    static func term(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let prefix = prefixes.first(where: { trimmed.lowercased().hasPrefix($0) }) else { return nil }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    static let defaultPrefix = "file: "

    static func isKnownExtension(_ ext: String) -> Bool {
        fileExtensions.contains(ext.lowercased())
    }

    private static let fileExtensions: Set<String> = [
        // 文档
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "md", "rtf", "csv", "epub",
        // 图片、设计
        "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "psd", "sketch", "fig", "tiff", "bmp", "ico", "icns",
        // 音视频
        "mp4", "mov", "mkv", "avi", "mp3", "wav", "m4a", "flac", "aac",
        // 压缩包、安装包
        "zip", "rar", "7z", "tar", "gz", "tgz", "dmg", "pkg", "iso", "ipa", "apk",
        // 代码与配置
        "swift", "js", "ts", "tsx", "jsx", "json", "py", "go", "rs", "java", "kt", "c", "h", "cpp", "m", "rb", "php",
        "html", "css", "scss", "vue", "sh", "zsh", "yml", "yaml", "toml", "xml", "sql", "log", "plist", "env", "lock",
    ]

    /// 没写 "file:" 但看起来是文件名、通配符或路径的输入，搜索时优先推荐文件搜索。
    /// 网址（WebAddress）优先于这里，调用方应先判断
    static func looksLikeFile(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, term(in: text) == nil else { return false }
        if PathQuery.isPath(text) || text.hasPrefix("./") { return text.count > 1 }
        if Glob.hasWildcard(text) { return text.count > 1 }
        let ext = (text as NSString).pathExtension.lowercased()
        let stem = (text as NSString).deletingPathExtension
        return !stem.isEmpty && fileExtensions.contains(ext)
    }

    /// 输入框里 term 之前的部分（保留用户输入的前缀写法），用于 Tab 补全时改写 term
    static func prefixPart(of text: String) -> String? {
        guard let term = term(in: text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return String(trimmed.dropLast(term.count))
    }
}

/// "file: ~/Down" 这类以 ~ 或 / 开头的输入：直接读目录，像终端补全一样列出条目
enum PathQuery {
    struct Listing {
        let directory: URL
        let entries: [URL]
        /// 目录不存在或无法读取
        let isMissing: Bool
    }

    static func isPath(_ term: String) -> Bool {
        term.hasPrefix("~") || term.hasPrefix("/")
    }

    static func list(_ term: String, limit: Int = 200) -> Listing {
        let expanded = (term as NSString).expandingTildeInPath
        // 以 / 结尾：列出该目录；否则列出上级目录中以最后一段开头（或包含）的条目
        let directoryPath = term.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
        let partial = term.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent.lowercased()
        let directory = URL(fileURLWithPath: directoryPath.isEmpty ? "/" : directoryPath, isDirectory: true)

        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return Listing(directory: directory, entries: [], isMissing: true)
        }

        // 默认隐藏以 . 开头的条目，除非用户正在输入它们
        let showHidden = partial.hasPrefix(".")
        let candidates = names.filter { showHidden || !$0.hasPrefix(".") }
        let matched = candidates
            .compactMap { name -> (name: String, rank: Int, isDirectory: Bool)? in
                let lower = name.lowercased()
                let rank: Int
                if Glob.hasWildcard(partial) {
                    // 如 ~/Downloads/*.dmg
                    guard Glob.matches(name, pattern: partial) else { return nil }
                    rank = 0
                } else if partial.isEmpty || lower.hasPrefix(partial) {
                    rank = 0
                } else if lower.contains(partial) {
                    rank = 1
                } else {
                    return nil
                }
                var isDir: ObjCBool = false
                fm.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDir)
                return (name, rank, isDir.boolValue)
            }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                // 列目录时文件夹在前
                if partial.isEmpty || Glob.hasWildcard(partial), $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(limit)

        return Listing(
            directory: directory,
            entries: matched.map { directory.appendingPathComponent($0.name, isDirectory: $0.isDirectory) },
            isMissing: false
        )
    }

    /// 把 URL 写回输入框的形式：用户目录缩写为 ~，文件夹末尾加 /
    static func display(_ url: URL) -> String {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        return isDir.boolValue && !path.hasSuffix("/") ? path + "/" : path
    }
}

/// 把搜索结果整理成列表行：按顶层目录分组（~/code、~/Documents…），组内是文件，中间路径作为灰色前缀
enum FileTree {
    struct Row {
        enum Action: Equatable {
            case open
            /// 「显示全部 N 个」：切换到该分组
            case showGroup(String)
        }

        var url: URL
        /// 显示在名称前的灰色路径，如 "all-in-aigc/thinkany/"
        var prefix: String
        var name: String
        var depth: Int
        /// 是搜索命中的条目（否则是分组行或「显示全部」）
        var isMatch: Bool
        var isDirectory: Bool
        /// 右侧的次要信息，如分组的结果数
        var detail: String? = nil
        var action: Action = .open
    }

    struct Group {
        let key: String
        let url: URL
        var files: [URL]
    }

    /// 路径模式：目录一行，其下是匹配的条目
    static func rows(directory: URL, entries: [URL]) -> [Row] {
        let path = (directory.path as NSString).abbreviatingWithTildeInPath
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let root = Row(url: directory, prefix: parent.isEmpty || parent == path ? "" : (parent.hasSuffix("/") ? parent : parent + "/"),
                       name: name, depth: 0, isMatch: false, isDirectory: true)
        return [root] + entries.map { url in
            Row(url: url, prefix: "", name: url.lastPathComponent, depth: 1, isMatch: true, isDirectory: url.hasDirectoryPath)
        }
    }

    /// 按用户目录下的第一层目录分组；files 已按相关度排序，分组按其中最靠前的结果排序
    static func groups(for files: [URL]) -> [Group] {
        let home = NSHomeDirectory()
        var groups: [Group] = []
        var indexByKey: [String: Int] = [:]
        for file in files {
            let path = file.standardizedFileURL.path
            let key: String
            let url: URL
            if path.hasPrefix(home + "/") {
                let components = path.dropFirst(home.count + 1).split(separator: "/")
                // 直接在 ~ 下的文件归入 "~" 组
                key = components.count > 1 ? String(components[0]) : "~"
                url = key == "~" ? URL(fileURLWithPath: home) : URL(fileURLWithPath: home).appendingPathComponent(key)
            } else {
                let first = path.split(separator: "/").first.map(String.init) ?? ""
                key = "/" + first
                url = URL(fileURLWithPath: key)
            }
            if let index = indexByKey[key] {
                groups[index].files.append(file)
            } else {
                indexByKey[key] = groups.count
                groups.append(Group(key: key, url: url, files: [file]))
            }
        }
        return groups
    }

    /// filter 为 nil 时显示所有分组，每组最多 perGroupLimit 条，超出的用「显示全部」行代替
    static func rows(for groups: [Group], filter: String?, perGroupLimit: Int) -> [Row] {
        var rows: [Row] = []
        for group in groups where filter == nil || group.key == filter {
            let title = (group.url.path as NSString).abbreviatingWithTildeInPath
            let parent = (title as NSString).deletingLastPathComponent
            rows.append(Row(url: group.url, prefix: parent.isEmpty || title == "~" ? "" : parent + "/",
                            name: (title as NSString).lastPathComponent, depth: 0, isMatch: false, isDirectory: true,
                            detail: "\(group.files.count)"))

            let shown = filter == nil ? Array(group.files.prefix(perGroupLimit)) : group.files
            let base = group.url.path.hasSuffix("/") ? group.url.path : group.url.path + "/"
            for file in shown {
                let relative = file.path.hasPrefix(base) ? String(file.path.dropFirst(base.count)) : file.path
                let directory = (relative as NSString).deletingLastPathComponent
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir)
                rows.append(Row(url: file, prefix: directory.isEmpty ? "" : directory + "/", name: file.lastPathComponent,
                                depth: 1, isMatch: true, isDirectory: isDir.boolValue))
            }
            if filter == nil, group.files.count > perGroupLimit {
                rows.append(Row(url: group.url, prefix: "", name: L10n.t("files.showAll", group.files.count),
                                depth: 1, isMatch: false, isDirectory: true, action: .showGroup(group.key)))
            }
        }
        return rows
    }
}

/// 竖向的文件树结果列表
final class FileTreeView: NSView {
    enum Metrics {
        static let rowHeight: CGFloat = 26
        static let indent: CGFloat = 14
        static let iconSize: CGFloat = 16
        /// 行内左边距；图标中心 = leading + depth * indent + iconSize / 2
        static let leading: CGFloat = 8
        static let horizontalPadding: CGFloat = 12
        static let headerHeight: CGFloat = 36
        static let filterBarHeight: CGFloat = 34
        static let bottomPadding: CGFloat = 8
        static let messageHeight: CGFloat = 60
    }

    struct Filter {
        /// nil 表示「全部」
        let key: String?
        let label: String
    }

    var onActivate: ((URL) -> Void)?
    /// 点击过滤按钮或「显示全部」行
    var onFilterChange: ((String?) -> Void)?

    private let filterBar = NSSegmentedControl()
    private var filters: [Filter] = []

    private(set) var rows: [FileTree.Row] = []
    private(set) var selectedIndex = 0
    private var rowViews: [FileRowView] = []
    private let header = SectionHeaderView()
    private let messageLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(header)
        filterBar.segmentStyle = .rounded
        filterBar.trackingMode = .selectOne
        filterBar.controlSize = .small
        filterBar.target = self
        filterBar.action = #selector(filterChanged)
        addSubview(filterBar)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        addSubview(messageLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedURL: URL? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex].url : nil
    }

    /// message 不为 nil 时显示提示（如「搜索中…」）而不是列表；filters 少于 2 个时不显示过滤栏。返回内容高度
    @discardableResult
    func update(rows: [FileTree.Row], title: String, detail: String?, message: String?,
                filters: [Filter] = [], selectedFilter: String? = nil,
                width: CGFloat, keepSelection: Bool) -> CGFloat {
        let previous = keepSelection ? selectedURL : nil
        self.rows = message == nil ? rows : []
        selectedIndex = previous.flatMap { url in self.rows.firstIndex { $0.url == url && $0.isMatch } }
            ?? self.rows.firstIndex(where: \.isMatch) ?? 0

        header.configure(title: title, detail: detail)
        header.frame = NSRect(x: Metrics.horizontalPadding, y: 0, width: width - Metrics.horizontalPadding * 2, height: Metrics.headerHeight)

        var y = Metrics.headerHeight
        self.filters = message == nil ? filters : []
        filterBar.isHidden = self.filters.count < 2
        if !filterBar.isHidden {
            filterBar.segmentCount = self.filters.count
            for (index, filter) in self.filters.enumerated() {
                filterBar.setLabel(filter.label, forSegment: index)
                filterBar.setWidth(0, forSegment: index)
            }
            filterBar.selectedSegment = self.filters.firstIndex { $0.key == selectedFilter } ?? 0
            filterBar.sizeToFit()
            let barWidth = min(filterBar.frame.width, width - Metrics.horizontalPadding * 2 - 8)
            filterBar.frame = NSRect(x: Metrics.horizontalPadding + 4, y: y, width: barWidth, height: 24)
            y += Metrics.filterBarHeight
        }
        if let message {
            messageLabel.isHidden = false
            messageLabel.stringValue = message
            messageLabel.frame = NSRect(x: 0, y: y + 18, width: width, height: 20)
            y += Metrics.messageHeight
        } else {
            messageLabel.isHidden = true
        }

        for (index, row) in self.rows.enumerated() {
            let view = rowView(at: index)
            view.frame = NSRect(x: Metrics.horizontalPadding, y: y, width: width - Metrics.horizontalPadding * 2, height: Metrics.rowHeight)
            view.configure(row)
            view.isSelected = index == selectedIndex
            view.isHidden = false
            view.onClick = { [weak self] in
                self?.select(index)
                self?.activateSelection()
            }
            y += Metrics.rowHeight
        }
        for view in rowViews[self.rows.count...] { view.isHidden = true }

        let height = y + Metrics.bottomPadding
        setFrameSize(NSSize(width: width, height: height))
        // 先回到顶部（露出标题和过滤栏），再确保选中行可见
        scroll(.zero)
        if rowViews.indices.contains(selectedIndex), !self.rows.isEmpty {
            rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
        }
        return height
    }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        select(max(0, min(rows.count - 1, selectedIndex + delta)))
    }

    func activateSelection() {
        guard rows.indices.contains(selectedIndex) else { return }
        let row = rows[selectedIndex]
        switch row.action {
        case .open: onActivate?(row.url)
        case .showGroup(let key): onFilterChange?(key)
        }
    }

    /// Tab / ⇧Tab 在过滤按钮间切换
    func cycleFilter(by delta: Int) {
        guard filters.count > 1 else { return }
        let current = max(filterBar.selectedSegment, 0)
        let next = (current + delta + filters.count) % filters.count
        onFilterChange?(filters[next].key)
    }

    @objc private func filterChanged() {
        guard filters.indices.contains(filterBar.selectedSegment) else { return }
        onFilterChange?(filters[filterBar.selectedSegment].key)
    }

    private func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rowViews[selectedIndex].isSelected = false
        selectedIndex = index
        rowViews[index].isSelected = true
        // 露出上下各一行，方便看到上下文
        rowViews[index].scrollToVisible(rowViews[index].bounds.insetBy(dx: 0, dy: -Metrics.rowHeight))
    }

    private func rowView(at index: Int) -> FileRowView {
        while rowViews.count <= index {
            let view = FileRowView()
            addSubview(view)
            rowViews.append(view)
        }
        return rowViews[index]
    }
}

private final class FileRowView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var depth = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .right
        addSubview(iconView)
        addSubview(label)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(_ row: FileTree.Row) {
        depth = row.depth
        detailLabel.stringValue = row.detail ?? ""
        if case .showGroup = row.action {
            iconView.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            iconView.contentTintColor = .secondaryLabelColor
            toolTip = nil
        } else {
            iconView.image = NSWorkspace.shared.icon(forFile: row.url.path)
            iconView.contentTintColor = nil
            toolTip = (row.url.path as NSString).abbreviatingWithTildeInPath
        }
        iconView.alphaValue = row.isMatch ? 1 : 0.7

        let text = NSMutableAttributedString()
        if !row.prefix.isEmpty {
            text.append(NSAttributedString(string: row.prefix, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        text.append(NSAttributedString(string: row.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: row.isMatch ? .medium : .regular),
            .foregroundColor: row.isMatch ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]))
        label.attributedStringValue = text
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        typealias M = FileTreeView.Metrics
        let x = M.leading + CGFloat(depth) * M.indent
        iconView.frame = NSRect(x: x, y: (bounds.height - M.iconSize) / 2, width: M.iconSize, height: M.iconSize)
        let detailWidth: CGFloat = detailLabel.stringValue.isEmpty ? 0 : 48
        detailLabel.frame = NSRect(x: bounds.width - detailWidth - 10, y: (bounds.height - 16) / 2, width: detailWidth, height: 16)
        label.frame = NSRect(x: x + M.iconSize + 6, y: (bounds.height - 17) / 2,
                             width: bounds.width - x - M.iconSize - 14 - detailWidth, height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        typealias M = FileTreeView.Metrics
        if isSelected {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        // 层级引导线：对齐各级上级目录图标的中心，用很淡的线（separatorColor 在毛玻璃上会显得很重）
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        for level in 0..<depth {
            let x = (M.leading + CGFloat(level) * M.indent + M.iconSize / 2).rounded(.down)
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return NSMouseInRect(superview.convert(point, to: self), bounds, isFlipped) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
