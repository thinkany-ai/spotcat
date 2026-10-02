import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags.rawValue
    var modifiers: UInt
    /// 按键显示名，录制时按当前键盘布局取得
    var key: String

    /// 默认快捷键 ⌘Space。没有手动设置时按 candidates 的顺序自动选第一个没被占用的
    static let `default` = candidates[0]

    /// ⌘Space > ⌥Space > ⌃Space > ⌘⇧Space > ⌥⇧Space
    static let candidates: [Shortcut] = [
        [.command], [.option], [.control], [.command, .shift], [.option, .shift],
    ].map { (flags: NSEvent.ModifierFlags) in
        Shortcut(keyCode: UInt32(kVK_Space), modifiers: flags.rawValue, key: "Space")
    }

    private static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// 从按键事件构造；必须带 ⌘/⌥/⌃ 之一（F 键除外），否则返回 nil
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.allowedModifiers)
        let code = Int(event.keyCode)
        let isFunctionKey = Self.functionKeys[code] != nil
        guard isFunctionKey || !flags.subtracting(.shift).isEmpty else { return nil }

        let name = Self.functionKeys[code]
            ?? Self.specialKeys[code]
            ?? event.characters(byApplyingModifiers: [])?.uppercased()
        guard let name, !name.isEmpty else { return nil }

        self.init(keyCode: UInt32(code), modifiers: flags.rawValue, key: name)
    }

    init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var displayString: String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + key
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let followSystem = "system"

    /// 手动设置的快捷键；没有时为自动模式
    private static let shortcutKey = "shortcut"
    /// 当前实际使用的快捷键，给同时运行的另一个版本（开发版 / 正式版）判断冲突用
    static let activeShortcutKey = "activeShortcut"
    private static let languageKey = "language"
    private static let appearanceKey = "appearance"
    private static let nicknameKey = "nickname"
    private static let disabledExtensionsKey = "disabledExtensions"
    private static let disabledFeaturesKey = "disabledFeatures"
    private static let quicklinksKey = "quicklinks"
    private static let searchEngineKey = "defaultSearchEngine"
    private static let showRecentsKey = "showRecents"
    private static let showSuggestionsKey = "showSuggestions"
    private static let autoCheckUpdatesKey = "autoCheckUpdates"
    private static let keepOpenKey = "keepOpen"

    @Published private(set) var shortcut: Shortcut
    @Published var shortcutError: String?
    /// 没有手动设置快捷键，按 Shortcut.candidates 自动选择
    @Published private(set) var isAutomaticShortcut: Bool
    /// 自动模式下没用上 ⌘Space 时，占用它的系统功能或应用
    @Published private(set) var defaultShortcutOwner: ShortcutConflicts.Owner?
    /// 自动模式下被跳过的候选及其占用者（按顺序，不含 ⌘Space）
    private(set) var skippedShortcuts: [(Shortcut, ShortcutConflicts.Owner)] = []
    private var isShortcutRegistered = false
    private var isRecordingShortcut = false
    private var loggedShortcut: Shortcut?
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @Published var launchAtLoginError: String?

    /// "system"、"zh-Hans" 或 "en"
    @Published var language: String {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language, forKey: Self.languageKey)
            onLanguageChange?()
        }
    }
    var onLanguageChange: (() -> Void)?

    /// 模型服务商与默认模型（数据目录/models.json）
    @Published var models: ModelsConfig {
        didSet { if models != oldValue { models.save() } }
    }

    /// "system"、"light" 或 "dark"
    @Published var appearance: String {
        didSet {
            guard appearance != oldValue else { return }
            UserDefaults.standard.set(appearance, forKey: Self.appearanceKey)
            applyAppearance()
        }
    }

    @Published var nickname: String {
        didSet { UserDefaults.standard.set(nickname, forKey: Self.nicknameKey) }
    }
    @Published private(set) var avatar: NSImage?

    /// 被禁用的扩展 id 和功能 id（"ext:<扩展>/<功能>"）
    @Published private(set) var disabledExtensions: Set<String>
    @Published private(set) var disabledFeatures: Set<String>
    var onExtensionsChange: (() -> Void)?

    @Published var quicklinks: [Quicklink] {
        didSet {
            guard quicklinks != oldValue else { return }
            if let data = try? JSONEncoder().encode(quicklinks) {
                UserDefaults.standard.set(data, forKey: Self.quicklinksKey)
            }
        }
    }
    /// 搜索结果各区块的开关
    @Published var showRecents: Bool {
        didSet { saveSearchOption(showRecents, Self.showRecentsKey) }
    }
    @Published var showSuggestions: Bool {
        didSet { saveSearchOption(showSuggestions, Self.showSuggestionsKey) }
    }
    /// 常驻：启动器失去焦点时不隐藏
    @Published var keepOpen: Bool {
        didSet { UserDefaults.standard.set(keepOpen, forKey: Self.keepOpenKey) }
    }
    @Published var autoCheckUpdates: Bool {
        didSet { UserDefaults.standard.set(autoCheckUpdates, forKey: Self.autoCheckUpdatesKey) }
    }

    /// 影响搜索结果的设置变化时回调（刷新面板）
    var onSearchOptionsChange: (() -> Void)?

    private func saveSearchOption(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onSearchOptionsChange?()
    }

    func clearUsageHistory() {
        UsageStore.clear()
        onSearchOptionsChange?()
    }

    /// 输入任意文字时「匹配推荐」里用哪个快捷链接做网页搜索；空字符串表示不显示
    @Published var defaultSearchEngine: String {
        didSet { UserDefaults.standard.set(defaultSearchEngine, forKey: Self.searchEngineKey) }
    }

    /// 由 AppDelegate 提供：注册全局快捷键（nil 表示注销），返回是否成功
    var hotKeyRegistrar: ((Shortcut?) -> Bool)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
            isAutomaticShortcut = false
        } else {
            shortcut = .default
            isAutomaticShortcut = true
        }
        language = UserDefaults.standard.string(forKey: Self.languageKey) ?? Self.followSystem
        appearance = UserDefaults.standard.string(forKey: Self.appearanceKey) ?? Self.followSystem
        nickname = UserDefaults.standard.string(forKey: Self.nicknameKey) ?? ""
        avatar = NSImage(contentsOf: Self.avatarURL)
        disabledExtensions = Set(UserDefaults.standard.stringArray(forKey: Self.disabledExtensionsKey) ?? [])
        disabledFeatures = Set(UserDefaults.standard.stringArray(forKey: Self.disabledFeaturesKey) ?? [])
        let savedQuicklinks = UserDefaults.standard.data(forKey: Self.quicklinksKey)
            .flatMap { try? JSONDecoder().decode([Quicklink].self, from: $0) }
        quicklinks = savedQuicklinks ?? Quicklink.defaults
        defaultSearchEngine = UserDefaults.standard.string(forKey: Self.searchEngineKey) ?? "google"
        let defaults = UserDefaults.standard
        showRecents = defaults.object(forKey: Self.showRecentsKey) as? Bool ?? true
        showSuggestions = defaults.object(forKey: Self.showSuggestionsKey) as? Bool ?? true
        keepOpen = defaults.bool(forKey: Self.keepOpenKey)
        autoCheckUpdates = defaults.object(forKey: Self.autoCheckUpdatesKey) as? Bool ?? true
        models = ModelsConfig.load()
        refreshLaunchAtLogin()
    }

    // MARK: - 快捷键

    /// 手动设置快捷键。被系统或其他应用占用时不接受，保留原来的
    func updateShortcut(_ new: Shortcut) {
        guard let register = hotKeyRegistrar else { return }
        if let owner = ShortcutConflicts.owner(of: new) {
            _ = register(shortcut)
            shortcutError = L10n.t("settings.shortcut.takenBy", new.displayString, owner.name)
        } else if register(new) {
            setActiveShortcut(new)
            isAutomaticShortcut = false
            defaultShortcutOwner = nil
            shortcutError = nil
            if let data = try? JSONEncoder().encode(new) {
                UserDefaults.standard.set(data, forKey: Self.shortcutKey)
            }
        } else {
            _ = register(shortcut)
            shortcutError = L10n.t("settings.shortcut.taken", new.displayString)
        }
    }

    /// 恢复默认：清除手动设置，回到自动模式（优先 ⌘Space）
    func useAutomaticShortcut() {
        UserDefaults.standard.removeObject(forKey: Self.shortcutKey)
        isAutomaticShortcut = true
        isShortcutRegistered = false
        shortcutError = nil
        applyShortcut()
    }

    /// 注册快捷键并检查冲突；启动时和之后定期调用（用户在系统设置或其他应用里改了快捷键后自动跟上）。
    /// 自动模式下按 Shortcut.candidates 的顺序选第一个没被占用的，占用解除后自动换回更靠前的
    func applyShortcut() {
        guard let register = hotKeyRegistrar, !isRecordingShortcut else { return }
        guard isAutomaticShortcut else {
            if !isShortcutRegistered {
                isShortcutRegistered = register(shortcut)
                if !isShortcutRegistered {
                    shortcutError = L10n.t("settings.shortcut.registerFailed", shortcut.displayString)
                    NSLog("%@", "Spotcat: \(shortcut.displayString) 注册失败")
                    return
                }
            }
            setActiveShortcut(shortcut)
            let error = ShortcutConflicts.owner(of: shortcut).map {
                L10n.t("settings.shortcut.takenBy", shortcut.displayString, $0.name)
            }
            if shortcutError != error { shortcutError = error }
            return
        }

        var skipped: [(Shortcut, ShortcutConflicts.Owner)] = []
        var chosen: Shortcut?
        for candidate in Shortcut.candidates {
            if let owner = ShortcutConflicts.owner(of: candidate) {
                skipped.append((candidate, owner))
                continue
            }
            if candidate == shortcut, isShortcutRegistered {
                chosen = candidate
                break
            }
            if register(candidate) {
                isShortcutRegistered = true
                chosen = candidate
                break
            }
        }
        // 全都被占用时仍然注册 ⌘Space，并在设置里提示
        if chosen == nil {
            isShortcutRegistered = register(.default)
            chosen = .default
        }
        let owner = skipped.first { $0.0 == .default }?.1
        skippedShortcuts = skipped.filter { $0.0 != .default }
        if defaultShortcutOwner != owner { defaultShortcutOwner = owner }
        let error = skipped.count == Shortcut.candidates.count
            ? L10n.t("settings.shortcut.allTaken") : nil
        if shortcutError != error { shortcutError = error }
        if let chosen {
            if chosen != loggedShortcut {
                let skippedText = skipped.map { "\($0.0.displayString)：\($0.1.name)" }.joined(separator: "，")
                NSLog("%@", "Spotcat: 快捷键 \(chosen.displayString)" + (skipped.isEmpty ? "" : "（跳过 \(skippedText)）"))
            }
            loggedShortcut = chosen
            setActiveShortcut(chosen)
        }
    }

    private func setActiveShortcut(_ new: Shortcut) {
        if shortcut != new { shortcut = new }
        if let data = try? JSONEncoder().encode(new), UserDefaults.standard.data(forKey: Self.activeShortcutKey) != data {
            UserDefaults.standard.set(data, forKey: Self.activeShortcutKey)
        }
    }

    /// 录制期间先注销当前快捷键，否则按下当前组合会被全局热键截走
    func setRecording(_ recording: Bool) {
        isRecordingShortcut = recording
        let registered = hotKeyRegistrar?(recording ? nil : shortcut) ?? false
        isShortcutRegistered = !recording && registered
    }

    // MARK: - 开机启动

    var launchAtLogin: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    // MARK: - 扩展启用状态

    func isExtensionEnabled(_ id: String) -> Bool {
        !disabledExtensions.contains(id)
    }

    func isFeatureEnabled(_ feature: ExtensionFeatureRef) -> Bool {
        isExtensionEnabled(feature.extensionID) && !disabledFeatures.contains(feature.id)
    }

    func setExtension(_ id: String, enabled: Bool) {
        if enabled { disabledExtensions.remove(id) } else { disabledExtensions.insert(id) }
        UserDefaults.standard.set(disabledExtensions.sorted(), forKey: Self.disabledExtensionsKey)
        onExtensionsChange?()
    }

    func setFeature(_ id: String, enabled: Bool) {
        if enabled { disabledFeatures.remove(id) } else { disabledFeatures.insert(id) }
        UserDefaults.standard.set(disabledFeatures.sorted(), forKey: Self.disabledFeaturesKey)
        onExtensionsChange?()
    }

    // MARK: - 快捷链接

    var searchEngine: Quicklink? {
        quicklinks.first { $0.id == defaultSearchEngine && $0.acceptsQuery }
    }

    /// 返回新条目的 id，设置页据此直接进入编辑
    @discardableResult
    func addQuicklink() -> String {
        let id = UUID().uuidString
        quicklinks.append(Quicklink(id: id, name: "", keyword: "", url: "https://"))
        return id
    }

    func removeQuicklink(_ id: String) {
        quicklinks.removeAll { $0.id == id }
    }

    func resetQuicklinks() {
        quicklinks = Quicklink.defaults
        defaultSearchEngine = "google"
    }

    // MARK: - 外观

    func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - 个人资料

    static var dataDirectory: URL {
        AppEnvironment.dataDirectory
    }

    private static var avatarURL: URL { dataDirectory.appendingPathComponent("avatar.png") }

    /// 裁成正方形并缩放到 256px 后保存为 PNG
    func setAvatar(from url: URL) {
        guard let source = NSImage(contentsOf: url),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let side = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let square = cg.cropping(to: crop) else { return }

        let size = 256
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: square, size: .zero).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        try? png.write(to: Self.avatarURL, options: .atomic)
        avatar = NSImage(data: png)
    }

    func removeAvatar() {
        try? FileManager.default.removeItem(at: Self.avatarURL)
        avatar = nil
    }

    // MARK: - 模型

    /// 服务商或模型变化后，保证默认模型仍然存在；否则改用第一个模型
    func normalizeDefaultModel() {
        let all = models.providers.flatMap { provider in provider.models.map { "\(provider.id)/\($0)" } }
        if !all.contains(models.defaultModel) { models.defaultModel = all.first ?? "" }
    }

    @discardableResult
    func addModelProvider() -> String {
        let preset = ModelsConfig.presets[0]
        let provider = ModelProvider(id: UUID().uuidString, name: preset.label, kind: preset.kind,
                                     apiBase: preset.apiBase, apiKey: "", models: [preset.model])
        models.providers.insert(provider, at: 0)
        normalizeDefaultModel()
        return provider.id
    }

    func removeModelProvider(_ id: String) {
        models.providers.removeAll { $0.id == id }
        normalizeDefaultModel()
    }
}
