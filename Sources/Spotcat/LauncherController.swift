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
    /// 常驻：失去焦点时不隐藏。跟随设置里的开关，扩展和聊天顶栏的图钉也改这个设置
    private var isPinned = false
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
    /// 开发版标签，只在搜索界面显示（扩展和聊天有自己的顶栏按钮）
    private var devBadge: BadgeView?
    private var lastHiddenAt: Date?
    private let iconCache = NSCache<NSString, NSImage>()
    /// 区分代码设置 frame 和用户拖动，只保存后者
    private var isSettingFrame = false
    /// 由主快捷键呼出时仍按着的修饰键（如 ⌘）。松开之前再按某个键，直接进入设了这个二级键的功能
    private var chordModifiers: NSEvent.ModifierFlags?

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

    /// 主快捷键：切换显示；呼出时记下仍按着的修饰键，开始等待二级键
    func hotKeyPressed() {
        guard !(panel.isVisible && panel.isKeyWindow) else { return hide() }
        show()
        let required = SettingsStore.shared.shortcut.flags.intersection(Self.chordModifierMask)
        chordModifiers = !required.isEmpty && NSEvent.modifierFlags.isSuperset(of: required) ? required : nil
    }

    private static let chordModifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// 支持在独立窗口打开的快捷键目标
    static func supportsDetached(_ targetID: String) -> Bool {
        targetID.hasPrefix("ext:") || targetID == LauncherItem.chatID
    }

    /// 在独立窗口打开；已经有这个功能的独立窗口时切过去。不支持时返回 false
    private func openDetached(_ targetID: String) -> Bool {
        switch item(forID: targetID) {
        case .feature(let feature, _)?:
            if let window = DetachedExtensionWindow.window(forFeature: feature.id) {
                hide()
                window.bringToFront()
                return true
            }
            guard let ext = extensions.owner(of: feature) else { return false }
            UsageStore.recordLaunch(id: feature.id)
            let host = ExtensionHostView(ext: ext, feature: feature, trigger: .keyword, payload: "")
            hide()
            DetachedExtensionWindow.present(host, at: detachedFrame()) { [weak self] request in
                self?.show()
                self?.openChat(request)
            }
            return true
        case .chat?:
            UsageStore.recordLaunch(id: LauncherItem.chatID)
            hide()
            if let window = DetachedChatWindow.all.last {
                window.bringToFront()
            } else if let chat = ChatView(request: ChatRequest()) {
                DetachedChatWindow.present(chat, at: detachedFrame())
            }
            return true
        default:
            return false
        }
    }

    /// 直接打开的独立窗口放在启动器展开成扩展时的位置
    private func detachedFrame() -> NSRect {
        let height = Layout.extensionHeight
        if let saved = savedTopLeft() {
            return NSRect(x: saved.x, y: saved.y - height, width: Layout.width, height: height)
        }
        let visible = (screenWithMouse() ?? NSScreen.main!).visibleFrame
        let top = visible.minY + visible.height * 0.75
        return NSRect(x: visible.midX - Layout.width / 2, y: top - height, width: Layout.width, height: height)
    }

    /// 用功能快捷键直接进入：AI 对话、扩展功能等（id 同「最近使用」的条目 id）。
    /// 已经停在这个功能里时再按一次就隐藏，和主快捷键一样是开关。
    /// detached 为 true 时在独立窗口打开（只有扩展功能和 AI 对话支持，其余照常在面板里打开）
    func open(targetID: String, detached: Bool = false) {
        chordModifiers = nil
        if detached, openDetached(targetID) { return }
        let isShowingTarget = (targetID == LauncherItem.chatID && chatView != nil)
            || (chatView == nil && activeHost?.featureID == targetID)
        if panel.isVisible, panel.isKeyWindow, isShowingTarget { return hide() }
        guard let item = item(forID: targetID) else { return NSSound.beep() }

        if !(panel.isVisible && panel.isKeyWindow) { show() }
        if chatView != nil { closeChat() }
        if activeHost != nil { exitExtension() }
        searchField.stringValue = ""
        search()
        activate(item)
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
        chordModifiers = nil
        panel.orderOut(nil)
        lastHiddenAt = Date()
    }

    /// 语言切换：重新加载扩展（名称、关键词随语言变化）并刷新界面文案
    func localeDidChange() {
        extensions.reload()
        index.invalidate()
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

        settings.$keepOpen
            .sink { [weak self] pinned in
                self?.isPinned = pinned
                self?.activeHost?.isPinned = pinned
            }
            .store(in: &cancellables)

        // 开发版在头像左边显示 DEV 标签，避免和正式版混淆
        var trailingX = avatarX
        if AppEnvironment.isDevelopment {
            let size = NSSize(width: 38, height: 18)
            trailingX = avatarX - size.width - 10
            let badge = BadgeView(text: "DEV", color: NSColor(srgbRed: 1, green: 0.69, blue: 0.13, alpha: 1))
            badge.frame = NSRect(x: trailingX, y: (Layout.searchHeight - size.height) / 2, width: size.width, height: size.height)
            badge.autoresizingMask = [.minXMargin]
            badge.toolTip = AppEnvironment.appName
            container.addSubview(badge)
            devBadge = badge
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
        panel.onFlagsChanged = { [weak self] event in
            guard let self, let chord = self.chordModifiers else { return }
            if !event.modifierFlags.isSuperset(of: chord) { self.chordModifiers = nil }
        }
        panel.keyDownInterceptor = { [weak self] event in
            guard let self else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // 二级快捷键：主快捷键的修饰键一直按着，再按设好的键。没设的键照常处理（如 ⌘V 粘贴）
            if let chord = self.chordModifiers, modifiers == chord,
               let key = event.characters(byApplyingModifiers: [])?.lowercased(), !key.isEmpty,
               let target = FeatureShortcuts.shared.target(forChordKey: key) {
                self.open(targetID: target)
                return true
            }
            if self.activeHost == nil, self.chatView == nil {
                guard event.keyCode == UInt16(kVK_Return), modifiers == .command,
                      let url = self.isFileMode ? self.fileTree.selectedURL : self.grid.selectedItem?.fileURL else { return false }
                self.hide()
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return true
            }
            guard event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty else { return false }
            if let chat = self.chatView {
                chat.handleEscape { [weak self] in self?.closeChat() }
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
            let builtins = BuiltinExtensions.enabled
            let candidates: [LauncherItem] = index.items.map { .app($0) }
                + extensions.enabledFeatures.map { feature in
                    let trigger: EnterTrigger = !feature.isKeyword(queryString) && feature.matches(text) ? .match : .keyword
                    return .feature(feature, trigger: trigger)
                }
                + builtins.flatMap { $0.items(query: queryString) }
            // 内置扩展的即时结果（如计算器）放在最前，↩ 直接复制
            let answers = builtins.flatMap { ext in
                ext.answers(for: text).map { answer in
                    ResultSection(title: ext.name, detail: L10n.t("answer.copyHint"), items: [.answer(answer)], layout: .wide)
                }
            }
            // 网址、像文件名的输入、「关键词 内容」的快捷链接放在最前，↩ 直接打开。
            // 算式里的 "." 会被当成文件名，有计算结果时不再提示搜索文件
            let pinned = builtins.flatMap { $0.pinnedItems(for: text) }.filter { item in
                if case .searchFiles = item { return answers.isEmpty }
                return true
            }
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
            let best = Array((pinned + ranked).prefix(Layout.maxResults))

            // 扩展通过 spotcat.search.setItems 提供的内容（如笔记），每个扩展一个分区
            let indexed = ExtensionSearchIndex.shared.search(text, in: extensions.enabledFeatures).map { group in
                ResultSection(title: group.extensionName, detail: nil, items: group.items.map { .indexed($0) }, layout: .list)
            }

            let bestIDs = Set(best.map(\.id))
            // 内置扩展的推荐（问 AI、网页搜索）在前，网页扩展的内容匹配在后。
            // 输入本身是网址、文件名或快捷链接时不再推荐网页搜索
            let builtinSuggestions = builtins.flatMap { $0.suggestions(for: text) }.filter { item in
                if case .webSearch = item { return pinned.isEmpty }
                return !bestIDs.contains(item.id)
            }
            let matched: [LauncherItem] = options.showSuggestions
                ? builtinSuggestions + extensions.enabledFeatures
                    .filter { !bestIDs.contains($0.id) && $0.matches(text) }
                    .map { .feature($0, trigger: .match) }
                : []

            sections = answers + [ResultSection(title: L10n.t("section.best"), detail: nil, items: best)] + indexed + [
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

    private func item(forID id: String) -> LauncherItem? {
        if let item = BuiltinExtensions.enabled.lazy.compactMap({ $0.item(forID: id) }).first { return item }
        if let file = FileItem(id: id) { return .file(file) }
        if id.hasPrefix("ext:") {
            return extensions.feature(id: id).map { .feature($0, trigger: .keyword) }
        }
        return index.items.first { $0.url.path == id }.map { .app($0) }
    }

    // MARK: - Actions

    private func activate(_ item: LauncherItem) {
        // 「搜索文件：xxx」只是切换到文件搜索，即时结果随输入而变，都不计入最近使用
        switch item {
        case .searchFiles, .answer, .indexed: break
        default: UsageStore.recordLaunch(id: item.id)
        }
        switch item {
        case .app(let app):
            launch(app)
        case .feature(let feature, let trigger):
            enterExtension(feature, trigger: trigger)
        case .indexed(let ref):
            enterExtension(ref.feature, trigger: .item, payload: ref.item.id)
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
        case .answer(let answer):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer.copyText, forType: .string)
            hide()
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

    /// payload 默认取搜索框内容（匹配进入时去掉首尾空白）
    private func enterExtension(_ feature: ExtensionFeatureRef, trigger: EnterTrigger, payload: String? = nil) {
        guard activeHost == nil, let ext = extensions.owner(of: feature) else { return }
        // 这个功能已经分离成独立窗口：切过去，不在启动器里再开一份
        if let window = DetachedExtensionWindow.window(forFeature: feature.id) {
            hide()
            window.bringToFront()
            return
        }
        let raw = searchField.stringValue
        let payload = payload ?? (trigger == .match ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw)

        let host = ExtensionHostView(ext: ext, feature: feature, trigger: trigger, payload: payload)
        host.onExit = { [weak self] in self?.exitExtension() }
        host.onHide = { [weak self] in self?.hide() }
        host.onOpenChat = { [weak self] request in self?.openChat(request) }
        host.onDetach = { [weak self] in self?.detachExtension() }
        host.isPinned = isPinned
        host.onPin = { SettingsStore.shared.keepOpen = $0 }
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

    /// 把当前扩展搬到独立窗口，启动器回到搜索并隐藏
    private func detachExtension() {
        guard let host = activeHost, chatView == nil else { return }
        let frame = panel.frame
        host.removeFromSuperview()
        activeHost = nil
        setSearchChromeHidden(false)
        search()
        hide()
        // 独立窗口里打开聊天：呼出启动器显示聊天
        DetachedExtensionWindow.present(host, at: frame) { [weak self] request in
            self?.show()
            self?.openChat(request)
        }
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
        case .extensions:
            (NSApp.delegate as? AppDelegate)?.showSettings(tab: .extensions)
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
        if request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           request.context.isEmpty, request.title == nil, request.source == nil,
           let window = DetachedChatWindow.all.last {
            hide()
            window.bringToFront()
            return
        }
        guard chatView == nil, let chat = ChatView(request: request) else { return }
        chat.onBack = { [weak self] in self?.closeChat() }
        chat.onHide = { [weak self] in self?.hide() }
        chat.onDetach = { [weak self] in self?.detachChat() }
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

    private func detachChat() {
        guard let chat = chatView else { return }
        let frame = panel.frame
        chat.removeFromSuperview()
        chatView = nil
        restoreAfterChat()
        hide()
        DetachedChatWindow.present(chat, at: frame)
    }

    private func closeChat() {
        guard let chat = chatView else { return }
        chat.teardown()
        chat.removeFromSuperview()
        chatView = nil
        restoreAfterChat()
    }

    private func restoreAfterChat() {
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
        devBadge?.isHidden = hidden
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
        case .indexed(let ref):
            image = extensions.owner(of: ref.feature).map { ExtensionIcon.image(for: $0, feature: ref.feature.feature) } ?? NSImage()
        case .chat:
            image = ExtensionIcon.symbolTile("bubble.left.and.bubble.right.fill", color: Theme.accentNSColor)
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
        case .answer(let answer):
            // 自带图标随结果变化（同一个 id），不缓存
            if let custom = answer.icon { return custom }
            guard let icon = BuiltinExtensions.get(answer.extensionID)?.icon else { return NSImage() }
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
        // 输入法组字中的按键（回车上屏、方向键选词等）交给输入法，不触发打开/移动选中
        guard !textView.hasMarkedText() else { return false }
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
        guard !isPinned, panel.attachedSheet == nil else { return }
        hide()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isSettingFrame, panel.isVisible else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.savedPositionKey)
    }
}
