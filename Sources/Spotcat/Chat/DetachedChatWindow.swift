import AppKit

/// 原样移动聊天 WebView，分离时保留草稿、附件、历史和正在生成的回复。
final class DetachedChatWindow: NSWindow {
    private(set) static var all: [DetachedChatWindow] = []
    private let chat: ChatView

    static func present(_ chat: ChatView, at frame: NSRect) {
        let window = DetachedChatWindow(chat: chat, frame: frame)
        chat.onBack = { [weak window] in window?.close() }
        chat.onHide = nil
        chat.onDetach = nil
        chat.onPin = { [weak window] pinned in window?.level = pinned ? .floating : .normal }
        chat.onTitleChange = { [weak window] title in window?.title = title }
        chat.setWindowState(detached: true, pinned: false)
        all.append(window)
        window.bringToFront()
        window.makeFirstResponder(chat.webView)
    }

    static func menuItems() -> [NSMenuItem] {
        all.map { window in
            let item = NSMenuItem(title: window.title, action: #selector(bringToFront), keyEquivalent: "")
            item.target = window
            item.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
            return item
        }
    }

    private init(chat: ChatView, frame: NSRect) {
        self.chat = chat
        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = chat.title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        toolbar = NSToolbar()
        toolbarStyle = .unified
        isReleasedWhenClosed = false
        minSize = NSSize(width: 420, height: 320)
        collectionBehavior = [.fullScreenNone]
        standardWindowButton(.zoomButton)?.isEnabled = false
        setFrame(frame, display: false)

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        contentView = effect
        chat.frame = effect.bounds
        chat.autoresizingMask = [.width, .height]
        effect.addSubview(chat)
    }

    @objc func bringToFront() {
        if isMiniaturized { deminiaturize(nil) }
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        guard let index = Self.all.firstIndex(of: self) else { return super.close() }
        chat.teardown()
        super.close()
        Self.all.remove(at: index)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            chat.handleEscape(fallback: {})
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "w": performClose(nil)
        case "m": performMiniaturize(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
