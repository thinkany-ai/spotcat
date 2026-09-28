import AppKit
import Carbon.HIToolbox
import Combine

final class LauncherController: NSObject {
    private enum Layout {
        static let width: CGFloat = 800
        static let searchHeight: CGFloat = 64
        static let maxGridHeight: CGFloat = 440
        /// 文件搜索的列表可以更高（和扩展面板一样的总高度）
        static let maxFileListHeight: CGFloat = 560 - 64 - 1
        static let filesPerGroup = 5
        static let extensionHeight: CGFloat = 560
        /// 隐藏超过这个时间再呼出，就退出扩展回到搜索
        static let extensionKeepAlive: TimeInterval = 90
        static let cornerRadius: CGFloat = 14
        static let horizontalPadding: CGFloat = 22
        static let avatarSize: CGFloat = 32
        static let maxResults = 45
        static let maxRecents = 18
    }

    private static let savedPositionKey = "panelTopLeft"

    private let panel = LauncherPanel()
    private let container = FlippedView()
    private let avatarButton = NSButton()
    private var cancellables = Set<AnyCancellable>()
    private let searchField = NSTextField()
    private let divider = NSBox()
    private let scrollView = NSScrollView()
    private let grid = ResultsGridView()
    private var gridHeight: CGFloat = 0

    private let index = AppIndex()
    private let extensions = ExtensionManager.shared
    private let fileSearch = FileSearch(limit: 100)
    /// 文件搜索当前只看哪个顶层目录（nil 为全部）；换了搜索词就重置
    private var fileFilter: String?
    private var fileFilterTerm = ""
    /// 最近一次文件搜索的结果，只在与当前 "file: xxx" 的 xxx 一致时显示
    private var fileResults: (query: String, files: [FileItem]) = ("", [])
    private let fileTree = FileTreeView()
    /// 输入以 "file:" 开头时，结果区显示文件树而不是网格
    private var isFileMode = false
    private var activeHost: ExtensionHostView?
    /// 聊天面板盖在扩展（或搜索）之上，返回时回到原处
    private var chatView: ChatView?
    private var lastHiddenAt: Date?
    private let iconCache = NSCache<NSString, NSImage>()
    /// 区分代码设置 frame 和用户拖动，只保存后者
    private var isSettingFrame = false

    override init() {
        super.init()
        buildUI()
        index.onUpdate = { [weak self] in self?.search() }
        FaviconCache.shared.onUpdate = { [weak self] in
            self?.iconCache.removeAllObjects()
            self?.search(keepSelection: true)
        }
        fileSearch.onResults = { [weak self] query, files in
            guard let self else { return }
            self.fileResults = (query, files)
            self.search(keepSelection: true)
        }
        extensions.reloadIfNeeded(maxAge: 0)
        search()
        index.refreshIfNeeded()
    }

    // MARK: - Show / hide

    func toggle() {
        panel.isVisible && panel.isKeyWindow ? hide() : show()
    }

    func show() {
        index.refreshIfNeeded()
        extensions.reloadIfNeeded()
        // 停留在扩展里太久再呼出就回到搜索；聊天不自动关闭，避免丢失对话
        if chatView == nil, activeHost != nil, let hiddenAt = lastHiddenAt,
           Date().timeIntervalSince(hiddenAt) > Layout.extensionKeepAlive {
            exitExtension()
        }
        updateFrame(anchorToScreen: true)
        panel.makeKeyAndOrderFront(nil)
        if let chat = chatView {
            panel.makeFirstResponder(chat.webView)
        } else if let host = activeHost {
            panel.makeFirstResponder(host.webView)
        } else {
            panel.makeFirstResponder(searchField)
            // 保留上次的查询并全选，和 Spotlight 一致
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    func hide() {
        panel.orderOut(nil)
        lastHiddenAt = Date()
    }

    /// 语言切换：重新加载扩展（名称、关键词随语言变化）并刷新界面文案
    func localeDidChange() {
        extensions.reload()
        iconCache.removeAllObjects()
        searchField.placeholderString = L10n.t("search.placeholder")
        search()
    }

    /// 扩展启用状态变化后刷新搜索结果
    func refreshResults() {
        search()
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.savedPositionKey)
    }

    // MARK: - UI

    private func buildUI() {
        panel.delegate = self
        // 先给面板正确的宽度，子视图按 800 宽布局；否则从 0 宽拉伸时 autoresizing 会把它们推偏
        panel.setFrame(NSRect(x: 0, y: 0, width: Layout.width, height: Layout.searchHeight), display: false)

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        // 用 maskImage 做圆角：layer.cornerRadius + masksToBounds 会让毛玻璃每帧离屏渲染
        effect.maskImage = .roundedMask(radius: Layout.cornerRadius)
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        container.frame = effect.bounds
        container.autoresizingMask = [.width, .height]
        effect.addSubview(container)

        // 右侧头像：点击打开设置的「个人资料」
        let avatarX = Layout.width - Layout.horizontalPadding - Layout.avatarSize
        avatarButton.frame = NSRect(x: avatarX, y: (Layout.searchHeight - Layout.avatarSize) / 2,
                                    width: Layout.avatarSize, height: Layout.avatarSize)
        avatarButton.autoresizingMask = [.minXMargin]
        avatarButton.isBordered = false
        avatarButton.title = ""
        avatarButton.imagePosition = .imageOnly
        avatarButton.imageScaling = .scaleProportionallyUpOrDown
        avatarButton.target = self
        avatarButton.action = #selector(openProfile)
        container.addSubview(avatarButton)

        let settings = SettingsStore.shared
        settings.$avatar.combineLatest(settings.$nickname)
            .receive(on: RunLoop.main)
            .sink { [weak self] avatar, nickname in
                self?.avatarButton.image = NSImage.avatar(avatar, name: nickname, size: Layout.avatarSize)
                self?.avatarButton.toolTip = nickname.isEmpty ? L10n.t("settings.tab.profile") : nickname
            }
            .store(in: &cancellables)

        // 开发版在头像左边显示 DEV 标签，避免和正式版混淆
        var trailingX = avatarX
        if AppEnvironment.isDevelopment {
            let badge = NSTextField(labelWithString: "DEV")
            badge.font = .systemFont(ofSize: 11, weight: .bold)
            badge.textColor = .black
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.69, blue: 0.13, alpha: 1).cgColor
            badge.layer?.cornerRadius = 5
            badge.toolTip = AppEnvironment.appName
            let size = NSSize(width: 38, height: 18)
            trailingX = avatarX - size.width - 10
            badge.frame = NSRect(x: trailingX, y: (Layout.searchHeight - size.height) / 2, width: size.width, height: size.height)
            badge.autoresizingMask = [.minXMargin]
            container.addSubview(badge)
        }

        searchField.frame = NSRect(x: Layout.horizontalPadding, y: (Layout.searchHeight - 34) / 2,
                                   width: trailingX - Layout.horizontalPadding - 12, height: 34)
        searchField.autoresizingMask = [.width]
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 26, weight: .light)
        searchField.placeholderString = L10n.t("search.placeholder")
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        container.addSubview(searchField)

        divider.boxType = .separator
        divider.frame = NSRect(x: 0, y: Layout.searchHeight, width: Layout.width, height: 1)
        divider.autoresizingMask = [.width]
        container.addSubview(divider)

        grid.iconProvider = { [weak self] item in self?.icon(for: item) ?? NSImage() }
        grid.onActivate = { [weak self] item in self?.activate(item) }
        fileTree.onActivate = { [weak self] url in self?.activate(.file(FileItem(url: url))) }
        fileTree.onFilterChange = { [weak self] key in
            self?.fileFilter = key
            self?.search()
        }

        // 搜索里 ⌘↩ 在访达中显示；扩展/聊天里按 Esc 返回上一级。在分发给第一响应者（含 WebView）之前拦截
        panel.keyDownInterceptor = { [weak self] event in
            guard let self else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if self.activeHost == nil, self.chatView == nil {
                guard event.keyCode == UInt16(kVK_Return), modifiers == .command,
                      let url = self.isFileMode ? self.fileTree.selectedURL : self.grid.selectedItem?.fileURL else { return false }
                self.hide()
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return true
            }
            guard event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty else { return false }
            if self.chatView != nil {
                self.closeChat()
            } else {
                self.exitExtension()
            }
            return true
        }

        scrollView.documentView = grid
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.autoresizingMask = [.width]
        container.addSubview(scrollView)
    }

    /// 根据结果数调整高度，顶边保持不动
    private func updateFrame(anchorToScreen: Bool = false) {
        let height: CGFloat
        if activeHost != nil || chatView != nil {
            height = Layout.extensionHeight
        } else {
            let listHeight = min(gridHeight, isFileMode ? Layout.maxFileListHeight : Layout.maxGridHeight)
            let isEmpty = listHeight == 0
            height = Layout.searchHeight + (isEmpty ? 0 : 1 + listHeight)

            divider.isHidden = isEmpty
            scrollView.isHidden = isEmpty
            scrollView.frame = NSRect(x: 0, y: Layout.searchHeight + 1, width: Layout.width, height: listHeight)
        }

        let top: CGFloat
        let x: CGFloat
        if anchorToScreen || !panel.isVisible, let saved = savedTopLeft() {
            top = saved.y
            x = saved.x
        } else if anchorToScreen || !panel.isVisible {
            let screen = screenWithMouse() ?? NSScreen.main!
            let visible = screen.visibleFrame
            top = visible.minY + visible.height * 0.75
            x = visible.midX - Layout.width / 2
        } else {
            top = panel.frame.maxY
            x = panel.frame.minX
        }
        // 尺寸不变时不动窗口，避免每次按键都重算毛玻璃和阴影
        let frame = NSRect(x: x, y: top - height, width: Layout.width, height: height)
        guard frame != panel.frame else { return }
        let sizeChanged = frame.size != panel.frame.size
        isSettingFrame = true
        panel.setFrame(frame, display: panel.isVisible)
        isSettingFrame = false
        if sizeChanged { panel.invalidateShadow() }
    }

    /// 用户拖过的位置；所在屏幕已断开时忽略
    private func savedTopLeft() -> NSPoint? {
        guard let value = UserDefaults.standard.string(forKey: Self.savedPositionKey) else { return nil }
        let point = NSPointFromString(value)
        let probe = NSPoint(x: point.x + Layout.width / 2, y: point.y - Layout.searchHeight / 2)
        return NSScreen.screens.contains { NSMouseInRect(probe, $0.visibleFrame, false) } ? point : nil
    }

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    // MARK: - Search

    /// keepSelection：同一查询的补充结果（如文件搜索返回）刷新时，保持当前选中项
    private func search(keepSelection: Bool = false) {
        // 在扩展/聊天里时，索引刷新等回调不应改动面板
        guard activeHost == nil, chatView == nil else { return }

        let raw = searchField.stringValue
        if let term = FileQuery.term(in: raw) {
            return searchFiles(term, keepSelection: keepSelection)
        }
        setFileMode(false)
        fileSearch.stop()

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = Array(raw.lowercased().filter { !$0.isWhitespace })
        let sections: [ResultSection]

        let options = SettingsStore.shared
        if query.isEmpty {
            let recents = options.showRecents ? UsageStore.recentIDs(limit: Layout.maxRecents).compactMap(item(forID:)) : []
            sections = [ResultSection(title: L10n.t("section.recent"), detail: nil, items: recents)]
        } else {
            // 输入是关键词（前缀）时按关键词进入；否则若内容规则也命中，按「匹配」进入并带上内容
            let queryString = String(query)
            let candidates: [LauncherItem] = index.items.map { .app($0) }
                + extensions.enabledFeatures.map { feature in
                    let trigger: EnterTrigger = !feature.isKeyword(queryString) && feature.matches(text) ? .match : .keyword
                    return .feature(feature, trigger: trigger)
                }
                + [.chat(trigger: LauncherItem.chatKeyword(queryString) ? .keyword : .match)]
                + BuiltinCommand.allCases.map { .command($0) }
                + SettingsStore.shared.quicklinks.map { .quicklink($0, query: nil) }
            let pinned = pinnedWebItems(for: text)
            let pinnedIDs = Set(pinned.map(\.id))
            let ranked = candidates
                .compactMap { item -> (LauncherItem, Int)? in
                    let score = item.searchKeys.compactMap { FuzzyMatcher.score(query: query, in: $0) }.max()
                    guard let score else { return nil }
                    return (item, score + min(UsageStore.count(for: item.id), 20) * 2)
                }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
                .map(\.0)
                .filter { !pinnedIDs.contains($0.id) }
            // 网址和「关键词 内容」的快捷链接放在最前，↩ 直接打开；
            // 关闭「最佳搜索结果」时只保留这些明确意图的置顶项
            let best = Array((pinned + (options.showBestMatches ? ranked : [])).prefix(Layout.maxResults))

            let bestIDs = Set(best.map(\.id))
            // 任意文本都可以直接问 AI，放在匹配推荐的第一位
            let askAI: [LauncherItem] = bestIDs.contains(LauncherItem.chatID) ? [] : [.chat(trigger: .match)]
            // 其次是用默认搜索引擎搜索整段输入（输入本身是网址或快捷链接时不重复出现）
            let webSearch: [LauncherItem] = pinned.isEmpty
                ? SettingsStore.shared.searchEngine.map { [.webSearch($0, query: text)] } ?? []
                : []
            let matched: [LauncherItem] = options.showSuggestions
                ? askAI + webSearch + extensions.enabledFeatures
                    .filter { !bestIDs.contains($0.id) && $0.matches(text) }
                    .map { .feature($0, trigger: .match) }
                : []

            sections = [
                ResultSection(title: L10n.t("section.best"), detail: nil, items: best),
                ResultSection(title: L10n.t("section.matches"), detail: nil, items: matched),
            ]
        }

        gridHeight = grid.update(sections: sections, width: Layout.width, keepSelection: keepSelection)
        updateFrame()
    }

    /// "file: xxx"：用 Spotlight 搜文件，以目录树列出
    private func searchFiles(_ term: String, keepSelection: Bool) {
        setFileMode(true)
        if PathQuery.isPath(term) {
            return browsePath(term, keepSelection: keepSelection)
        }
        fileSearch.search(term)

        let ready = fileResults.query == term
        let files = ready ? fileResults.files : []
        let message: String?
        if term.isEmpty {
            message = L10n.t("files.hint")
        } else if !ready {
            message = L10n.t("files.searching")
        } else if files.isEmpty {
            message = L10n.t("files.empty")
        } else {
            message = nil
        }

        if term != fileFilterTerm {
            fileFilterTerm = term
            fileFilter = nil
        }
        let groups = FileTree.groups(for: files.map(\.url))
        if let filter = fileFilter, !groups.contains(where: { $0.key == filter }) { fileFilter = nil }
        let filters = [FileTreeView.Filter(key: nil, label: L10n.t("files.all", files.count))]
            + groups.map { FileTreeView.Filter(key: $0.key, label: "\($0.key) \($0.files.count)") }

        gridHeight = fileTree.update(
            rows: FileTree.rows(for: groups, filter: fileFilter, perGroupLimit: Layout.filesPerGroup),
            title: L10n.t("section.files"),
            detail: files.isEmpty ? L10n.t("files.shortcuts") : L10n.t("files.detail", files.count),
            message: message,
            filters: filters,
            selectedFilter: fileFilter,
            width: Layout.width,
            keepSelection: keepSelection
        )
        updateFrame()
    }

    /// "file: ~/Down"：直接列目录，Tab 补全
    private func browsePath(_ term: String, keepSelection: Bool) {
        fileSearch.stop()
        let listing = PathQuery.list(term)
        let message: String? = listing.isMissing ? L10n.t("files.missingDirectory")
            : listing.entries.isEmpty ? L10n.t("files.noEntries") : nil
        gridHeight = fileTree.update(
            rows: FileTree.rows(directory: listing.directory, entries: listing.entries),
            title: L10n.t("section.files"),
            detail: L10n.t("files.pathDetail", listing.entries.count),
            message: message,
            width: Layout.width,
            keepSelection: keepSelection
        )
        updateFrame()
    }

    /// 路径模式下 Tab：把选中条目补全到输入框，文件夹末尾加 / 以便继续浏览
    private func completePath() -> Bool {
        guard let prefix = FileQuery.prefixPart(of: searchField.stringValue),
              let term = FileQuery.term(in: searchField.stringValue), PathQuery.isPath(term),
              let url = fileTree.selectedURL else { return false }
        searchField.stringValue = prefix + PathQuery.display(url)
        search()
        searchField.currentEditor()?.moveToEndOfDocument(nil)
        return true
    }

    private func setFileMode(_ enabled: Bool) {
        guard enabled != isFileMode else { return }
        isFileMode = enabled
        scrollView.documentView = enabled ? fileTree : grid
    }

    /// 输入是网址 → 打开网址；像文件名/路径 → 搜索文件；以快捷链接关键词开头 → 该快捷链接（带上后面的内容）
    private func pinnedWebItems(for text: String) -> [LauncherItem] {
        var items: [LauncherItem] = []
        if let url = WebAddress.url(from: text) {
            items.append(.url(url))
        } else if FileQuery.looksLikeFile(text) {
            items.append(.searchFiles(text))
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

    private func item(forID id: String) -> LauncherItem? {
        if id.hasPrefix("url:"), let url = URL(string: String(id.dropFirst(4))) { return .url(url) }
        if id.hasPrefix("quicklink:") {
            let linkID = String(id.dropFirst("quicklink:".count))
            return SettingsStore.shared.quicklinks.first { $0.id == linkID }.map { .quicklink($0, query: nil) }
        }
        if id == LauncherItem.chatID { return .chat(trigger: .keyword) }
        if let command = BuiltinCommand.allCases.first(where: { $0.id == id }) { return .command(command) }
        if let file = FileItem(id: id) { return .file(file) }
        if id.hasPrefix("ext:") {
            return extensions.feature(id: id).map { .feature($0, trigger: .keyword) }
        }
        return index.items.first { $0.url.path == id }.map { .app($0) }
    }

    // MARK: - Actions

    private func activate(_ item: LauncherItem) {
        // 「搜索文件：xxx」只是切换到文件搜索，不计入最近使用
        if case .searchFiles = item {} else { UsageStore.recordLaunch(id: item.id) }
        switch item {
        case .app(let app):
            launch(app)
        case .feature(let feature, let trigger):
            enterExtension(feature, trigger: trigger)
        case .command(let command):
            run(command)
        case .file(let file):
            hide()
            NSWorkspace.shared.open(file.url)
        case .url(let url):
            hide()
            NSWorkspace.shared.open(url)
        case .quicklink(let link, let query):
            openQuicklink(link, query: query)
        case .webSearch(let link, let query):
            openQuicklink(link, query: query)
        case .searchFiles(let term):
            // 补上 file: 前缀，切到文件搜索（面板保持打开）
            searchField.stringValue = FileQuery.defaultPrefix + term
            search()
            searchField.currentEditor()?.moveToEndOfDocument(nil)
        case .chat(let trigger):
            // 从搜索框带着文字进入时直接提问
            let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            openChat(ChatRequest(prompt: trigger == .match ? text : nil, send: trigger == .match && !text.isEmpty))
        }
    }

    private func launch(_ item: AppItem) {
        hide()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: config) { _, error in
            if let error { NSLog("%@", "Spotcat: 启动 \(item.name) 失败：\(error)") }
        }
    }

    private func enterExtension(_ feature: ExtensionFeatureRef, trigger: EnterTrigger) {
        guard activeHost == nil, let ext = extensions.owner(of: feature) else { return }
        let raw = searchField.stringValue
        let payload = trigger == .match ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw

        let host = ExtensionHostView(ext: ext, feature: feature, trigger: trigger, payload: payload)
        host.onExit = { [weak self] in self?.exitExtension() }
        host.onHide = { [weak self] in self?.hide() }
        host.onOpenChat = { [weak self] request in self?.openChat(request) }
        activeHost = host
        setSearchChromeHidden(true)

        updateFrame()
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.makeFirstResponder(host.webView)
    }

    private func exitExtension() {
        guard let host = activeHost else { return }
        host.teardown()
        host.removeFromSuperview()
        activeHost = nil
        setSearchChromeHidden(false)

        search()
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    private func openQuicklink(_ link: Quicklink, query: String?) {
        guard let url = link.resolvedURL(query: query) else { return NSSound.beep() }
        hide()
        NSWorkspace.shared.open(url)
    }

    private func run(_ command: BuiltinCommand) {
        switch command {
        case .settings:
            (NSApp.delegate as? AppDelegate)?.showSettings()
        case .searchFiles:
            // 切到文件搜索，等待输入文件名
            searchField.stringValue = FileQuery.defaultPrefix
            search()
            searchField.currentEditor()?.moveToEndOfDocument(nil)
        }
    }

    @objc private func openProfile() {
        (NSApp.delegate as? AppDelegate)?.showSettings(tab: .profile)
    }

    private func openChat(_ request: ChatRequest) {
        guard chatView == nil, let chat = ChatView(request: request) else { return }
        chat.onBack = { [weak self] in self?.closeChat() }
        chat.onHide = { [weak self] in self?.hide() }
        chatView = chat

        if let host = activeHost {
            host.isHidden = true
        } else {
            setSearchChromeHidden(true)
        }
        updateFrame()
        chat.frame = container.bounds
        chat.autoresizingMask = [.width, .height]
        container.addSubview(chat)
        panel.makeFirstResponder(chat.webView)
    }

    private func closeChat() {
        guard let chat = chatView else { return }
        chat.teardown()
        chat.removeFromSuperview()
        chatView = nil

        if let host = activeHost {
            host.isHidden = false
            panel.makeFirstResponder(host.webView)
        } else {
            setSearchChromeHidden(false)
            search()
            panel.makeFirstResponder(searchField)
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    private func setSearchChromeHidden(_ hidden: Bool) {
        avatarButton.isHidden = hidden
        searchField.isHidden = hidden
        if hidden {
            divider.isHidden = true
            scrollView.isHidden = true
        }
    }

    private func icon(for item: LauncherItem) -> NSImage {
        let key = item.id as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let image: NSImage
        switch item {
        case .app(let app):
            image = NSWorkspace.shared.icon(forFile: app.url.path)
        case .feature(let feature, _):
            image = extensions.owner(of: feature).map { ExtensionIcon.image(for: $0, feature: feature.feature) } ?? NSImage()
        case .chat:
            image = ExtensionIcon.symbolTile("sparkles", color: .systemPurple)
        case .command(let command):
            image = ExtensionIcon.symbolTile(command.icon.symbol, color: command.icon.color)
        case .file(let file):
            image = NSWorkspace.shared.icon(forFile: file.url.path)
        case .url(let url):
            return webIcon(host: url.host)
        case .quicklink(let link, _), .webSearch(let link, _):
            return webIcon(host: link.host)
        case .searchFiles:
            let icon = BuiltinCommand.searchFiles.icon
            image = ExtensionIcon.symbolTile(icon.symbol, color: icon.color)
        }
        iconCache.setObject(image, forKey: key)
        return image
    }

    /// 网站 favicon；还没下载到时先用地球图标（不缓存，下载完成后会刷新）
    private func webIcon(host: String?) -> NSImage {
        if let host, let favicon = FaviconCache.shared.icon(for: host) { return ExtensionIcon.faviconTile(favicon) }
        return ExtensionIcon.symbolTile("globe", color: .systemTeal)
    }
}

// MARK: - NSTextFieldDelegate

extension LauncherController: NSTextFieldDelegate {
    private static let textEditingSelectors: Set<Selector> = [
        #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
        #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
    ]

    func controlTextDidChange(_ obj: Notification) {
        search()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)) where isFileMode:
            fileTree.moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)) where isFileMode:
            fileTree.moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)) where isFileMode:
            fileTree.activateSelection()
        case #selector(NSResponder.insertTab(_:)) where isFileMode:
            // 路径模式补全；文件搜索时切换目录过滤
            if !completePath() { fileTree.cycleFilter(by: 1) }
        case #selector(NSResponder.insertBacktab(_:)) where isFileMode:
            fileTree.cycleFilter(by: -1)
        // 文件模式下左右键和 Tab 保持编辑输入框（注意 where 只作用于单个 case 模式，所以显式判断）
        case _ where isFileMode && Self.textEditingSelectors.contains(selector):
            return false
        case #selector(NSResponder.moveDown(_:)):
            grid.moveSelection(.down)
        case #selector(NSResponder.moveUp(_:)):
            grid.moveSelection(.up)
        // 有结果时左右键/Tab 在网格里移动（和 uTools 一致），没有结果时仍然移动光标
        case #selector(NSResponder.moveLeft(_:)) where !grid.items.isEmpty:
            grid.moveSelection(.left)
        case #selector(NSResponder.moveRight(_:)) where !grid.items.isEmpty,
             #selector(NSResponder.insertTab(_:)) where !grid.items.isEmpty:
            grid.moveSelection(.right)
        case #selector(NSResponder.insertBacktab(_:)) where !grid.items.isEmpty:
            grid.moveSelection(.left)
        case #selector(NSResponder.insertNewline(_:)):
            grid.activateSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                hide()
            } else {
                searchField.stringValue = ""
                search()
            }
        default:
            return false
        }
        return true
    }
}

// MARK: - NSWindowDelegate

extension LauncherController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isSettingFrame, panel.isVisible else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.savedPositionKey)
    }
}
