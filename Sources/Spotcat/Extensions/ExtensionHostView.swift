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
    static let headerHeight: CGFloat = 64

    var webView: WKWebView { bridge.webView }
    var onExit: (() -> Void)?
    var onHide: (() -> Void)?
    var onOpenChat: ((ChatRequest) -> Void)?

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
        header = BreadcrumbView(
            icon: ExtensionIcon.image(for: ext),
            extensionName: ext.manifest.name,
            featureTitle: feature.feature.title
        )

        super.init(frame: .zero)

        api.emit = { [weak self] event, payload in self?.bridge.emit(event, payload) }
        bridge.handler = { [weak self] method, args, reply in
            self?.handle(method: method, args: args, reply: reply) ?? false
        }
        header.onClose = { [weak self] in self?.onExit?() }

        addSubview(header)
        addSubview(bridge.webView)
        bridge.load(ext.mainURL, readAccess: ext.directory)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        webView.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: bounds.height - Self.headerHeight)
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
}

/// 顶部面包屑：[图标 扩展名 / 功能名 ×]
final class BreadcrumbView: NSView {
    var onClose: (() -> Void)?

    private let pill = NSView()

    init(icon: NSImage, extensionName: String, featureTitle: String) {
        super.init(frame: .zero)

        pill.wantsLayer = true
        pill.layer?.cornerRadius = 18
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        let iconView = NSImageView(image: icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameLabel = NSTextField(labelWithString: extensionName)
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let slash = NSTextField(labelWithString: "/")
        slash.font = .systemFont(ofSize: 15, weight: .light)
        slash.textColor = .tertiaryLabelColor

        let featureLabel = NSTextField(labelWithString: featureTitle)
        featureLabel.font = .systemFont(ofSize: 15)
        featureLabel.textColor = .secondaryLabelColor

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.t("extension.exit"))!, target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = L10n.t("extension.exit")

        let stack = NSStackView(views: [iconView, nameLabel, slash, featureLabel, close])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(12, after: featureLabel)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePillColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePillColor()
    }

    private func updatePillColor() {
        // CGColor 不会跟随外观变化，切换深浅色时重新取
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
