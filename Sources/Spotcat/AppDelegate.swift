import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var launcher: LauncherController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var shortcutTimer: Timer?
    /// 本次运行提示过改用 ⌘Space，之后换上 ⌘Space 时告诉用户已生效
    private var didPromptForDefaultShortcut = false
    private static let suppressShortcutPromptKey = "suppressDefaultShortcutPrompt"

    private let settings = SettingsStore.shared
    private lazy var settingsWindow = SettingsWindowController(store: settings)

    static func main() {
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
        settings.applyShortcut()
        // 用户在系统设置或其他应用里改了快捷键后，几秒内自动换到更靠前的候选（最好是 ⌘Space）
        shortcutTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshShortcut()
        }

        setupMainMenu()
        setupStatusItem()

        DispatchQueue.main.async { [weak self] in
            self?.promptForDefaultShortcutIfNeeded()
        }

        Updater.shared.startAutomaticChecks()

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

    private func refreshShortcut() {
        let before = settings.shortcut
        settings.applyShortcut()
        guard didPromptForDefaultShortcut, before != .default, settings.shortcut == .default else { return }
        didPromptForDefaultShortcut = false
        let alert = NSAlert()
        alert.messageText = L10n.t("shortcut.prompt.doneTitle", Shortcut.default.displayString)
        alert.informativeText = L10n.t("shortcut.prompt.doneMessage", Shortcut.default.displayString)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 自动模式下 ⌘Space 被占用时，提示用户解除占用；没解除前先用自动选出的候选
    private func promptForDefaultShortcutIfNeeded() {
        guard settings.isAutomaticShortcut, let owner = settings.defaultShortcutOwner, owner != .spotcat,
              !UserDefaults.standard.bool(forKey: Self.suppressShortcutPromptKey) else { return }
        showDefaultShortcutPrompt(owner: owner, allowSuppress: true)
    }

    /// 设置页也会调用（「如何改用 ⌘Space」）
    func showDefaultShortcutPrompt(owner: ShortcutConflicts.Owner, allowSuppress: Bool) {
        let preferred = Shortcut.default.displayString
        let alert = NSAlert()
        alert.messageText = L10n.t("shortcut.prompt.title", preferred)

        var lines: [String] = []
        switch owner {
        case .system:
            lines.append(L10n.t("shortcut.prompt.system", preferred, owner.name))
        case .app, .spotcat:
            lines.append(L10n.t("shortcut.prompt.app", preferred, owner.name, owner.name))
        }
        let others = settings.skippedShortcuts.filter { $0.1 != .spotcat }
        if !others.isEmpty {
            let list = others.map { L10n.t("shortcut.prompt.takenItem", $0.0.displayString, $0.1.name) }
            lines.append(L10n.t("shortcut.prompt.alsoTaken", list.joined(separator: L10n.t("shortcut.prompt.separator"))))
        }
        lines.append(L10n.t("shortcut.prompt.fallback", settings.shortcut.displayString, preferred))
        alert.informativeText = lines.joined(separator: "\n\n")

        switch owner {
        case .system:
            alert.addButton(withTitle: L10n.t("shortcut.prompt.openKeyboard"))
        case .app(let name, _):
            alert.addButton(withTitle: L10n.t("shortcut.prompt.openApp", name))
        case .spotcat:
            alert.addButton(withTitle: L10n.t("shortcut.prompt.ok"))
        }
        alert.addButton(withTitle: L10n.t("shortcut.prompt.later", settings.shortcut.displayString))
        alert.showsSuppressionButton = allowSuppress
        alert.suppressionButton?.title = L10n.t("shortcut.prompt.dontRemind")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.suppressShortcutPromptKey)
        }
        guard response == .alertFirstButtonReturn else { return }
        didPromptForDefaultShortcut = true
        switch owner {
        case .system:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
                NSWorkspace.shared.open(url)
            }
        case .app(_, let bundleID):
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        case .spotcat:
            break
        }
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
            statusItem.button?.toolTip = AppEnvironment.appName
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
        // 第一行显示版本，区分正式版和开发版
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let title = NSMenuItem(title: "\(AppEnvironment.appName) \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if let release = Updater.shared.availableRelease {
            let update = NSMenuItem(title: L10n.t("update.menu", release.version), action: #selector(showUpdate), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: L10n.t("menu.open", settings.shortcut.displayString), action: #selector(openLauncher), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settingsItem = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let reset = NSMenuItem(title: L10n.t("menu.resetPosition"), action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        // 分离出去的扩展窗口，点击切过去
        let detached = DetachedExtensionWindow.menuItems()
        if !detached.isEmpty {
            menu.addItem(.separator())
            detached.forEach(menu.addItem)
        }
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

    @objc private func showUpdate() {
        showSettings(tab: .about)
    }

    @objc func resetPosition() {
        launcher.resetPosition()
    }
}
