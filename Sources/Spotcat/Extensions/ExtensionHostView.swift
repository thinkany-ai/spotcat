import AppKit
import WebKit

enum ExtensionIcon {
    /// 功能图标优先，其次扩展图标；"sf:<名字>" 渲染成彩色圆角方块 + 白色符号
    static func image(for ext: SpotcatExtension, feature: FeatureManifest? = nil) -> NSImage {
        let spec = feature?.icon ?? ext.manifest.icon
        let color = NSColor(hex: feature?.iconColor ?? ext.manifest.iconColor) ?? .systemBlue

        if let spec, spec.hasPrefix("sf:") {
            return symbolTile(String(spec.dropFirst(3)), color: color)
        }
        if let spec, let image = NSImage(contentsOf: ext.directory.appendingPathComponent(spec)) {
            return image
        }
        return symbolTile("puzzlepiece.extension.fill", color: color)
    }

    /// favicon 通常只有 16/32px，放在白色圆角底上居中显示，避免放大后模糊
    static func faviconTile(_ favicon: NSImage) -> NSImage {
        let size: CGFloat = 64
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 13, yRadius: 13)
            NSColor.white.setFill()
            tile.fill()
            NSColor.black.withAlphaComponent(0.08).setStroke()
            tile.lineWidth = 1
            tile.stroke()
            let inner: CGFloat = 32
            favicon.draw(in: NSRect(x: (size - inner) / 2, y: (size - inner) / 2, width: inner, height: inner))
            return true
        }
    }

    static func symbolTile(_ name: String, color: NSColor) -> NSImage {
        let size: CGFloat = 64
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 13, yRadius: 13).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 进入扩展后替换搜索界面：顶部面包屑 + 扩展页面（WKWebView）。
/// 每次进入新建 WebView，退出即销毁，扩展之间互不影响。
final class ExtensionHostView: NSView {

    var webView: WKWebView { bridge.webView }
    var onExit: (() -> Void)?
    var onHide: (() -> Void)?
    var onOpenChat: ((ChatRequest) -> Void)?
    var onDetach: (() -> Void)?
    var onPin: ((Bool) -> Void)?
    /// 图钉按钮的状态；由外部设置时不触发 onPin
    var isPinned: Bool {
        get { header.isPinned }
        set { header.isPinned = newValue }
    }
    /// 分离成独立窗口后顶栏放进透明标题栏，和红绿灯同一行
    var headerStyle: BreadcrumbView.Style {
        get { header.style }
        set {
            header.style = newValue
            needsLayout = true
        }
    }
    /// 独立窗口的标题：扩展名 · 功能名
    let title: String
    let icon: NSImage
    /// 再次进入同一功能时，用来找到已分离的窗口
    let featureID: String

    private let header: BreadcrumbView
    private let bridge: WebBridge
    private let api: ExtensionAPI
    /// 打开聊天时作为来源显示
    private let sourceName: String

    init(ext: SpotcatExtension, feature: ExtensionFeatureRef, trigger: EnterTrigger, payload: String) {
        bridge = WebBridge(context: [
            "enter": ["code": feature.feature.code, "type": trigger.rawValue, "payload": payload],
            "i18n": ["locale": ext.l10n.locale, "messages": ext.l10n.messages],
        ])
        api = ExtensionAPI(ext: ext)
        sourceName = ext.manifest.name
        // 只显示扩展名：扩展页面里通常有自己的标签页，进入时的功能名切换后就不准了
        title = ext.manifest.name
        icon = ExtensionIcon.image(for: ext)
        featureID = feature.id
        header = BreadcrumbView(icon: icon, extensionName: ext.manifest.name)

        super.init(frame: .zero)

        api.emit = { [weak self] event, payload in self?.bridge.emit(event, payload) }
        bridge.handler = { [weak self] method, args, reply in
            self?.handle(method: method, args: args, reply: reply) ?? false
        }
        header.onClose = { [weak self] in self?.onExit?() }
        header.onDetach = { [weak self] in self?.onDetach?() }
        header.onPin = { [weak self] pinned in self?.onPin?(pinned) }

        // 本地 / 开发中的扩展可以用 Safari 的「开发」菜单调试页面（右键「检查元素」）
        if #available(macOS 13.3, *) {
            webView.isInspectable = !ext.source.isStore || AppEnvironment.isDevelopment
        }

        addSubview(header)
        addSubview(bridge.webView)
        bridge.load(ext.mainURL, readAccess: ext.directory)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let headerHeight = header.style.height
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        webView.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: bounds.height - headerHeight)
    }

    func teardown() {
        api.teardown()
        bridge.teardown()
    }

    private func handle(method: String, args: [String: Any], reply: @escaping WebBridge.Reply) -> Bool {
        switch method {
        case "copyText":
            guard let text = args["text"] as? String else { reply(nil, "copyText requires text"); break }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            reply(true, nil)
        case "hideWindow":
            reply(true, nil)
            onHide?()
        case "paste":
            // 写入剪贴板，隐藏面板，粘贴到前台应用
            guard let text = args["text"] as? String else { reply(nil, "paste requires text"); break }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            pasteToFrontApp(reply: reply)
        case "clipboard.paste":
            guard api.isGranted(.clipboard) else { reply(nil, L10n.t("error.permission", "clipboard")); break }
            guard ClipboardHistory.shared.copy(id: args["id"] as? String ?? "") else { reply(nil, "No clipboard item"); break }
            pasteToFrontApp(reply: reply)
        case "exit":
            reply(true, nil)
            onExit?()
        case "chat.open":
            reply(true, nil)
            onOpenChat?(ChatRequest(args: args, source: sourceName))
        default:
            return api.handle(method: method, args: args, reply: reply)
        }
        return true
    }

    /// 返回 false 表示缺少辅助功能权限：内容已在剪贴板，面板保持打开，由页面提示用户
    private func pasteToFrontApp(reply: WebBridge.Reply) {
        guard AXIsProcessTrusted() else {
            _ = Paster.paste()
            return reply(false, nil)
        }
        onHide?()
        reply(Paster.paste(), nil)
    }
}

/// 扩展统一顶栏，样式与聊天页顶栏一致：
/// - 启动器里：[‹ 图标 扩展名 · 功能名 ……… 常驻 分离]
/// - 独立窗口里放进透明标题栏：[● ● ● 图标 扩展名 · 功能名 ……… 置顶]
final class BreadcrumbView: NSView {
    enum Style {
        case launcher, titlebar

        var height: CGFloat { self == .launcher ? 54 : 52 }
        /// 与聊天页 .topbar 的 padding（14px 14px 8px 10px）对齐；标题栏里让出红绿灯，并和它垂直居中
        fileprivate var leading: CGFloat { self == .launcher ? 10 : 96 }
        fileprivate var top: CGFloat { self == .launcher ? 14 : 10 }
    }

    var onClose: (() -> Void)?
    var onDetach: (() -> Void)?
    var onPin: ((Bool) -> Void)?

    var style: Style = .launcher {
        didSet { applyStyle() }
    }

    private let back = HoverButton(image: BreadcrumbView.symbol("chevron.left"))
    private let detach = HoverButton(image: BreadcrumbView.symbol("macwindow.on.rectangle"))
    private let pin = HoverButton(image: BreadcrumbView.symbol("pin"))
    /// 启动器里是「常驻」（失去焦点不隐藏），独立窗口里是「置顶」
    var isPinned = false {
        didSet { updatePin() }
    }
    private var leadingConstraint: NSLayoutConstraint!
    private var topConstraints: [NSLayoutConstraint] = []

    init(icon: NSImage, extensionName: String) {
        super.init(frame: .zero)

        back.target = self
        back.action = #selector(closeClicked)
        back.toolTip = L10n.t("extension.exit")
        back.setAccessibilityLabel(L10n.t("extension.exit"))
        detach.target = self
        detach.action = #selector(detachClicked)
        detach.toolTip = L10n.t("extension.detach")
        detach.setAccessibilityLabel(L10n.t("extension.detach"))
        pin.target = self
        pin.action = #selector(pinClicked)

        let iconView = NSImageView(image: icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameLabel = NSTextField(labelWithString: extensionName)
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [back, iconView, nameLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setCustomSpacing(4, after: back)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let trailing = NSStackView(views: [pin, detach])
        trailing.orientation = .horizontal
        trailing.spacing = 4
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailing)

        leadingConstraint = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        topConstraints = [
            stack.topAnchor.constraint(equalTo: topAnchor),
            trailing.topAnchor.constraint(equalTo: topAnchor),
        ]
        NSLayoutConstraint.activate(topConstraints + [
            leadingConstraint,
            back.widthAnchor.constraint(equalToConstant: 32),
            detach.widthAnchor.constraint(equalToConstant: 32),
            pin.widthAnchor.constraint(equalToConstant: 32),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            stack.heightAnchor.constraint(equalToConstant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
            trailing.heightAnchor.constraint(equalToConstant: 32),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    private func applyStyle() {
        back.isHidden = style == .titlebar
        detach.isHidden = style == .titlebar
        updatePin()
        leadingConstraint.constant = style.leading
        topConstraints.forEach { $0.constant = style.top }
    }

    private func updatePin() {
        let prefix = style == .launcher ? "launcher" : "extension"
        let label = L10n.t(isPinned ? "\(prefix).unpin" : "\(prefix).pin")
        pin.image = Self.symbol(isPinned ? "pin.fill" : "pin")
        pin.isActive = isPinned
        pin.toolTip = label
        pin.setAccessibilityLabel(label)
    }

    fileprivate static func symbol(_ name: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
    }

    @objc private func closeClicked() {
        onClose?()
    }

    @objc private func detachClicked() {
        onDetach?()
    }

    @objc private func pinClicked() {
        isPinned.toggle()
        onPin?(isPinned)
    }
}

/// 无边框图标按钮，悬停时显示圆角底色（对应聊天页的 .icon-btn:hover）
private final class HoverButton: NSButton {
    private var hovering = false { didSet { updateAppearance() } }
    /// 开关按钮打开时保持高亮（对应聊天页的 .icon-btn.active）
    var isActive = false { didSet { updateAppearance() } }

    convenience init(image: NSImage) {
        self.init(frame: .zero)
        self.image = image
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 8
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let highlighted = hovering || isActive
        contentTintColor = highlighted ? .labelColor : .secondaryLabelColor
        // CGColor 不会跟随外观变化，切换深浅色时重新取
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = highlighted ? NSColor.labelColor.withAlphaComponent(0.07).cgColor : nil
        }
    }
}
