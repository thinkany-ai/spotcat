import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags.rawValue
    var modifiers: UInt
    /// 按键显示名，录制时按当前键盘布局取得
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.option.rawValue, key: "Space")

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

    private static let shortcutKey = "shortcut"
    private static let languageKey = "language"
    private static let appearanceKey = "appearance"
    private static let nicknameKey = "nickname"
    private static let disabledExtensionsKey = "disabledExtensions"
    private static let disabledFeaturesKey = "disabledFeatures"
    private static let quicklinksKey = "quicklinks"
    private static let searchEngineKey = "defaultSearchEngine"
    private static let showRecentsKey = "showRecents"
    private static let showBestMatchesKey = "showBestMatches"
    private static let showSuggestionsKey = "showSuggestions"

    @Published private(set) var shortcut: Shortcut
    @Published var shortcutError: String?
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

    @Published var ai: AIConfig {
        didSet {
            guard ai != oldValue else { return }
            ai.save()
            aiTestStatus = .idle
        }
    }
    @Published private(set) var aiTestStatus: AITestStatus = .idle

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
    @Published var showBestMatches: Bool {
        didSet { saveSearchOption(showBestMatches, Self.showBestMatchesKey) }
    }
    @Published var showSuggestions: Bool {
        didSet { saveSearchOption(showSuggestions, Self.showSuggestionsKey) }
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
        } else {
            shortcut = .default
        }
        language = UserDefaults.standard.string(forKey: Self.languageKey) ?? Self.followSystem
        appearance = UserDefaults.standard.string(forKey: Self.appearanceKey) ?? Self.followSystem
        nickname = UserDefaults.standard.string(forKey: Self.nicknameKey) ?? ""
        avatar = NSImage(contentsOf: Self.avatarURL)
        disabledExtensions = Set(UserDefaults.standard.stringArray(forKey: Self.disabledExtensionsKey) ?? [])
        disabledFeatures = Set(UserDefaults.standard.stringArray(forKey: Self.disabledFeaturesKey) ?? [])
        quicklinks = UserDefaults.standard.data(forKey: Self.quicklinksKey)
            .flatMap { try? JSONDecoder().decode([Quicklink].self, from: $0) } ?? Quicklink.defaults
        defaultSearchEngine = UserDefaults.standard.string(forKey: Self.searchEngineKey) ?? "google"
        let defaults = UserDefaults.standard
        showRecents = defaults.object(forKey: Self.showRecentsKey) as? Bool ?? true
        showBestMatches = defaults.object(forKey: Self.showBestMatchesKey) as? Bool ?? true
        showSuggestions = defaults.object(forKey: Self.showSuggestionsKey) as? Bool ?? true
        ai = AIConfig.load()
        refreshLaunchAtLogin()
    }

    // MARK: - 快捷键

    func updateShortcut(_ new: Shortcut) {
        guard let register = hotKeyRegistrar else { return }
        if register(new) {
            shortcut = new
            shortcutError = nil
            if let data = try? JSONEncoder().encode(new) {
                UserDefaults.standard.set(data, forKey: Self.shortcutKey)
            }
        } else {
            _ = register(shortcut)
            shortcutError = L10n.t("settings.shortcut.taken", new.displayString)
        }
    }

    /// 录制期间先注销当前快捷键，否则按下当前组合会被全局热键截走
    func setRecording(_ recording: Bool) {
        _ = hotKeyRegistrar?(recording ? nil : shortcut)
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

    func addQuicklink() {
        quicklinks.append(Quicklink(id: UUID().uuidString, name: "", keyword: "", url: "https://"))
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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotcat", isDirectory: true)
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

    // MARK: - AI

    enum AITestStatus: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    /// 发一条极短的请求验证配置
    func testAI() {
        aiTestStatus = .testing
        Task { @MainActor in
            do {
                let reply = try await AIService.shared.chat(messages: [["role": "user", "content": "Reply with the single word: OK"]])
                aiTestStatus = .success(reply.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                aiTestStatus = .failure(error.localizedDescription)
            }
        }
    }

    func applyAIPreset(_ id: String) {
        guard let preset = AIConfig.presets.first(where: { $0.id == id }) else { return }
        var config = ai
        config.preset = id
        if id != AIConfig.customPresetID {
            config.baseURL = preset.baseURL
            config.model = preset.model
        }
        ai = config
    }
}

/// OpenAI 兼容接口配置。含 API Key，单独存成仅当前用户可读的文件（0600），不放 UserDefaults
struct AIConfig: Codable, Equatable {
    struct Preset {
        let id: String
        let name: String
        let baseURL: String
        let model: String
    }

    static let customPresetID = "custom"
    static let presets: [Preset] = [
        Preset(id: "siliconflow", name: "硅基流动 SiliconFlow", baseURL: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-7B-Instruct"),
        Preset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        Preset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini"),
        Preset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        Preset(id: customPresetID, name: "", baseURL: "", model: ""),
    ]

    var preset: String
    var baseURL: String
    var apiKey: String
    var model: String

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var providerName: String {
        preset == Self.customPresetID
            ? (URL(string: baseURL)?.host ?? L10n.t("settings.ai.custom"))
            : Self.presets.first { $0.id == preset }?.name ?? preset
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotcat/ai.json")
    }

    static func load() -> AIConfig {
        if let data = try? Data(contentsOf: fileURL), let config = try? JSONDecoder().decode(AIConfig.self, from: data) {
            return config
        }
        let first = presets[0]
        return AIConfig(preset: first.id, baseURL: first.baseURL, apiKey: "", model: first.model)
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
