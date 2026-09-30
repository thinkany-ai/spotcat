import AppKit
import Carbon.HIToolbox

/// 全局快捷键占用检测。Carbon 的 RegisterEventHotKey 不会因为其他应用注册了同一组合而失败
/// （两个应用都能注册成功，只有一个收得到），所以要自己查：系统快捷键和正在运行的常见启动器
enum ShortcutConflicts {
    enum Owner: Equatable {
        /// 系统快捷键，如聚焦、切换输入法
        case system(name: String)
        case app(name: String, bundleID: String)
        /// 同时运行的另一个版本的 Spotcat（开发版 / 正式版），不用提示
        case spotcat

        var name: String {
            switch self {
            case .system(let name): return name
            case .app(let name, _): return name
            case .spotcat: return "Spotcat"
            }
        }
    }

    /// 占用该快捷键的系统功能或应用；没有冲突返回 nil
    static func owner(of shortcut: Shortcut) -> Owner? {
        if let name = systemOwner(of: shortcut) { return .system(name: name) }
        return appOwner(of: shortcut)
    }

    // MARK: - 系统快捷键

    private static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    private static func systemOwner(of shortcut: Shortcut) -> String? {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let hotKeys = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let taken = hotKeys.contains { hotKey in
            guard (hotKey[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = hotKey[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = hotKey[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            return UInt32(code) == shortcut.keyCode && UInt32(modifiers) & modifierMask == shortcut.carbonModifiers
        }
        return taken ? systemName(for: shortcut) : nil
    }

    /// 常见系统快捷键的功能名，其余统称「系统快捷键」
    private static func systemName(for shortcut: Shortcut) -> String {
        guard shortcut.keyCode == UInt32(kVK_Space) else { return L10n.t("shortcut.owner.system") }
        switch shortcut.flags {
        case .command: return L10n.t("shortcut.owner.spotlight")
        case [.command, .option]: return L10n.t("shortcut.owner.finderSearch")
        case .control, [.control, .option]: return L10n.t("shortcut.owner.inputSource")
        case [.control, .command]: return L10n.t("shortcut.owner.emoji")
        default: return L10n.t("shortcut.owner.system")
        }
    }

    // MARK: - 其他应用

    private struct KnownApp {
        let bundleID: String
        let name: String
        /// 读取该应用当前的快捷键；读不到时按它的默认值
        let shortcut: () -> Shortcut?
    }

    private static let optionSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: NSEvent.ModifierFlags.option.rawValue, key: "Space")

    private static let knownApps: [KnownApp] = [
        // Raycast：defaults 里形如 "Shift-Command-49"，默认 ⌥Space
        KnownApp(bundleID: "com.raycast.macos", name: "Raycast") {
            guard let value = UserDefaults(suiteName: "com.raycast.macos")?.string(forKey: "raycastGlobalHotkey") else {
                return optionSpace
            }
            return parseRaycast(value)
        },
        // Alfred：偏好设置包里的 hotkey/prefs.plist（key 为键码，mod 为 NSEvent 修饰键），默认 ⌥Space
        KnownApp(bundleID: "com.runningwithcrayons.Alfred", name: "Alfred") {
            alfredHotKey() ?? optionSpace
        },
        // uTools 的设置存在数据库里读不到，按默认 ⌥Space
        KnownApp(bundleID: "org.yuanli.utools", name: "uTools") { optionSpace },
    ]

    private static let spotcatBundleIDs = ["ai.thinkany.spotcat", "ai.thinkany.spotcat.dev"]

    private static func appOwner(of shortcut: Shortcut) -> Owner? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for app in knownApps where running.contains(app.bundleID) {
            if let used = app.shortcut(), used.matches(shortcut) {
                return .app(name: app.name, bundleID: app.bundleID)
            }
        }
        for bundleID in spotcatBundleIDs where bundleID != Bundle.main.bundleIdentifier && running.contains(bundleID) {
            if let used = otherSpotcatShortcut(bundleID: bundleID), used.matches(shortcut) {
                return .spotcat
            }
        }
        return nil
    }

    /// 另一个版本的 Spotcat 正在用的快捷键（它写在自己 defaults 的 activeShortcut 里）
    private static func otherSpotcatShortcut(bundleID: String) -> Shortcut? {
        UserDefaults(suiteName: bundleID)?.data(forKey: SettingsStore.activeShortcutKey)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    private static func parseRaycast(_ value: String) -> Shortcut? {
        var parts = value.split(separator: "-").map(String.init)
        guard let last = parts.popLast(), let keyCode = UInt32(last) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "Command": flags.insert(.command)
            case "Option": flags.insert(.option)
            case "Control": flags.insert(.control)
            case "Shift": flags.insert(.shift)
            default: break
            }
        }
        return Shortcut(keyCode: keyCode, modifiers: flags.rawValue, key: "")
    }

    private static func alfredHotKey() -> Shortcut? {
        let local = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Alfred/Alfred.alfredpreferences/preferences/local")
        guard let machines = try? FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) else { return nil }
        for machine in machines {
            let url = machine.appendingPathComponent("hotkey/prefs.plist")
            guard let prefs = NSDictionary(contentsOf: url),
                  let key = prefs["key"] as? Int, let mod = prefs["mod"] as? Int else { continue }
            return Shortcut(keyCode: UInt32(key), modifiers: UInt(mod), key: "")
        }
        return nil
    }
}

private extension Shortcut {
    /// 只比较键码和修饰键（显示名可能不同）
    func matches(_ other: Shortcut) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }
}
