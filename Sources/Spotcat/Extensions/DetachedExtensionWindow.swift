import AppKit

/// 从启动器分离出来的扩展窗口：普通可调整大小的窗口，WebView 原样搬过来，页面状态不丢。
/// 关闭窗口即退出扩展。Spotcat 仍是菜单栏 App、不进 Dock，被挡住的窗口从启动器
/// （再次进入同一功能）或菜单栏图标的菜单切回来。
final class DetachedExtensionWindow: NSWindow {
    /// 窗口关闭前保持引用，按打开顺序
    private(set) static var all: [DetachedExtensionWindow] = []

    private let host: ExtensionHostView

    /// frame 为分离前启动器面板的位置，新窗口与之重合
    static func present(_ host: ExtensionHostView, at frame: NSRect, onOpenChat: @escaping (ChatRequest) -> Void) {
        let window = DetachedExtensionWindow(host: host, frame: frame)
        host.onExit = { [weak window] in window?.close() }
        // 独立窗口里「隐藏窗口」没有意义，忽略
        host.onHide = nil
        host.onDetach = nil
        host.onPin = { [weak window] pinned in window?.level = pinned ? .floating : .normal }
        host.onOpenChat = onOpenChat
        all.append(window)

        // accessory App 需要主动激活，窗口才能拿到焦点
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host.webView)
    }

    /// 已分离的同一功能的窗口
    static func window(forFeature id: String) -> DetachedExtensionWindow? {
        all.first { $0.host.featureID == id }
    }

    /// 菜单栏菜单：列出分离窗口，点击切过去
    static func menuItems() -> [NSMenuItem] {
        all.map { window in
            let item = NSMenuItem(title: window.title, action: #selector(DetachedExtensionWindow.bringToFront), keyEquivalent: "")
            item.target = window
            let image = window.host.icon.copy() as! NSImage
            image.size = NSSize(width: 16, height: 16)
            item.image = image
            return item
        }
    }

    private init(host: ExtensionHostView, frame: NSRect) {
        self.host = host
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = host.title
        // 标题栏透明，由扩展顶栏（图标 + 名称）占据，和启动器里的样式一致
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // 空工具栏让标题栏变高（52pt），红绿灯和顶栏内容垂直居中
        toolbar = NSToolbar()
        toolbarStyle = .unified
        isReleasedWhenClosed = false
        minSize = NSSize(width: 420, height: 320)
        collectionBehavior = [.fullScreenPrimary]
        setFrame(frame, display: false)

        // 和启动器一样的毛玻璃背景，WebView 背景透明
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        contentView = effect

        host.headerStyle = .titlebar
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
    }

    @objc func bringToFront() {
        if isMiniaturized { deminiaturize(nil) }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        guard let index = Self.all.firstIndex(of: self) else { return super.close() }
        host.teardown()
        super.close()
        Self.all.remove(at: index)
    }

    /// 没有「窗口」菜单，⌘W / ⌘M 在这里处理
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w": close()
        case "m": miniaturize(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
