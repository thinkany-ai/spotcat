import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var launcher: LauncherController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!

    private let settings = SettingsStore.shared
    private lazy var settingsWindow = SettingsWindowController(store: settings)

    static func main() {
        migrateLegacyDefaults()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 不出现在 Dock 和 ⌘Tab 中（直接 swift run 时 Info.plist 的 LSUIElement 不生效，这里兜底）
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.applyAppearance()
        launcher = LauncherController()

        settings.hotKeyRegistrar = { [weak self] shortcut in
            self?.registerHotKey(shortcut) ?? false
        }
        if !registerHotKey(settings.shortcut) {
            let name = settings.shortcut.displayString
            settings.shortcutError = L10n.t("settings.shortcut.registerFailed", name)
            NSLog("%@", "Spotcat: \(name) 注册失败")
        }

        setupMainMenu()
        setupStatusItem()

        settings.onSearchOptionsChange = { [weak self] in
            self?.launcher.refreshResults()
        }
        settings.onExtensionsChange = { [weak self] in
            self?.launcher.refreshResults()
        }
        settings.onLanguageChange = { [weak self] in
            self?.setupMainMenu()
            self?.launcher.localeDidChange()
            self?.settingsWindow.localeDidChange()
        }
    }

    /// 菜单栏不显示（accessory App），但需要 Edit 菜单，设置窗口里的输入框才能用 ⌘C/⌘V 等快捷键
    private func setupMainMenu() {
        let main = NSMenu()
        // 第一项固定是应用菜单；不放「退出 ⌘Q」，避免在面板里误触退出
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L10n.t("menu.edit"))
        edit.addItem(NSMenuItem(title: L10n.t("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L10n.t("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L10n.t("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L10n.t("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L10n.t("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L10n.t("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// Bundle ID 从 ai.trys.spotcat 改为 ai.thinkany.spotcat 后，把旧设置（快捷键、语言、快捷链接等）复制过来一次
    private static func migrateLegacyDefaults() {
        let legacyID = "ai.trys.spotcat"
        let marker = "migratedFromLegacyBundleID"
        let defaults = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != legacyID, !defaults.bool(forKey: marker) else { return }
        if let legacy = defaults.persistentDomain(forName: legacyID) {
            for (key, value) in legacy where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }

    /// 替换当前全局快捷键；nil 表示只注销
    private func registerHotKey(_ shortcut: Shortcut?) -> Bool {
        hotKey = nil
        guard let shortcut else { return true }
        let newHotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) { [weak self] in
            self?.launcher.toggle()
        }
        guard newHotKey.isRegistered else { return false }
        hotKey = newHotKey
        return true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 模板图标：系统按菜单栏深浅自动着色；直接 swift run 时没有资源，退回 SF Symbol
        if let icon = Bundle.main.image(forResource: "MenuBarIcon") {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = icon
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Spotcat")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 每次打开时重建，文案和快捷键随设置变化
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: L10n.t("menu.open", settings.shortcut.displayString), action: #selector(openLauncher), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settingsItem = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let reset = NSMenuItem(title: L10n.t("menu.resetPosition"), action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openLauncher() {
        launcher.show()
    }

    @objc func openSettings(_ sender: Any?) {
        showSettings()
    }

    func showSettings(tab: SettingsTab? = nil) {
        launcher.hide()
        settingsWindow.show(tab: tab)
    }

    @objc func resetPosition() {
        launcher.resetPosition()
    }
}
