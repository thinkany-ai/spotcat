import AppKit

/// 功能快捷键，对象是可以直接进入的条目（网页扩展的功能 ext:<id>/<code>、内置的 builtin:chat 等）：
/// - 二级键：按住主快捷键的修饰键不松开，呼出 Spotcat 后再按这个键直接进入，如 ⌘Space 接着 ⌘A 进入 AI 对话
/// - 全局快捷键：不用先呼出主窗口，任何时候按下直接进入
final class FeatureShortcuts: ObservableObject {
    static let shared = FeatureShortcuts()

    /// 连按时保留给编辑的键：⌘Space 后接 ⌘V 粘贴搜索词很常见
    static let reservedChordKeys: Set<String> = ["c", "v", "x", "z", ","]
    private static let defaultChordKeys = [LauncherItem.chatID: "a"]

    private static let chordKeysKey = "featureChordKeys"
    private static let hotKeysKey = "featureHotKeys"
    private static let detachedKey = "featureHotKeysDetached"

    /// 目标 id → 单个字符（小写）
    @Published private(set) var chordKeys: [String: String]
    /// 目标 id → 全局快捷键
    @Published private(set) var hotKeys: [String: Shortcut]
    /// 按全局快捷键时在独立窗口打开的目标（默认在启动器面板里打开）
    @Published private(set) var detachedTargets: Set<String>
    /// 正在录制快捷键时暂停全部全局快捷键，否则按下已注册的组合会直接触发
    private(set) var isRecording = false
    /// 全局快捷键变化（或录制开始/结束）时由 AppDelegate 重新注册
    var onHotKeysChange: (() -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        chordKeys = defaults.dictionary(forKey: Self.chordKeysKey) as? [String: String] ?? Self.defaultChordKeys
        hotKeys = defaults.data(forKey: Self.hotKeysKey)
            .flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
        detachedTargets = Set(defaults.stringArray(forKey: Self.detachedKey) ?? [])
    }

    func setDetached(_ detached: Bool, for id: String) {
        if detached { detachedTargets.insert(id) } else { detachedTargets.remove(id) }
        UserDefaults.standard.set(detachedTargets.sorted(), forKey: Self.detachedKey)
    }

    func target(forChordKey key: String) -> String? {
        chordKeys.first { $0.value == key }?.key
    }

    /// 返回错误提示；nil 表示已保存。key 为 nil 时清除
    func setChordKey(_ key: String?, for id: String) -> String? {
        if let key {
            if Self.reservedChordKeys.contains(key) {
                return L10n.t("shortcuts.reserved", key.uppercased())
            }
            if let other = target(forChordKey: key), other != id {
                return L10n.t("shortcuts.usedBy", Self.title(for: other))
            }
        }
        chordKeys[id] = key
        UserDefaults.standard.set(chordKeys, forKey: Self.chordKeysKey)
        return nil
    }

    func setHotKey(_ shortcut: Shortcut?, for id: String) -> String? {
        if let shortcut {
            if shortcut == SettingsStore.shared.shortcut {
                return L10n.t("shortcuts.mainShortcut")
            }
            if let other = hotKeys.first(where: { $0.value == shortcut && $0.key != id })?.key {
                return L10n.t("shortcuts.usedBy", Self.title(for: other))
            }
            if let owner = ShortcutConflicts.owner(of: shortcut), owner != .spotcat {
                return L10n.t("settings.shortcut.takenBy", shortcut.displayString, owner.name)
            }
        }
        hotKeys[id] = shortcut
        if let data = try? JSONEncoder().encode(hotKeys) {
            UserDefaults.standard.set(data, forKey: Self.hotKeysKey)
        }
        onHotKeysChange?()
        return nil
    }

    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        // 主快捷键也一起暂停
        SettingsStore.shared.setRecording(recording)
        onHotKeysChange?()
    }

    /// 二级键连同主快捷键一起显示，如「⌘Space › A」，和全局快捷键区分开
    static func chordDisplay(_ key: String) -> String {
        "\(SettingsStore.shared.shortcut.displayString) › \(key.uppercased())"
    }

    /// 设置页和冲突提示里显示的名称
    static func title(for id: String) -> String {
        if let target = BuiltinExtensions.all.flatMap(\.shortcutTargets).first(where: { $0.id == id }) {
            return target.title
        }
        if let feature = ExtensionManager.shared.allFeatures.first(where: { $0.id == id }) {
            let ext = ExtensionManager.shared.owner(of: feature)?.manifest.name
            return ext.map { $0 == feature.feature.title ? $0 : "\($0) · \(feature.feature.title)" } ?? feature.feature.title
        }
        return id
    }
}
