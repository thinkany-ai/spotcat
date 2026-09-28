import AppKit

/// 不激活 App 的浮动面板：弹出时前台应用保持激活，但面板能接收键盘输入。
final class LauncherPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovable = true
        // 拖动输入框周围的空白区域（放大镜、边距）即可移动面板，点输入框内部仍是编辑文字
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 在事件分发给第一响应者（包括 WKWebView）之前拦截按键，返回 true 表示已处理
    var keyDownInterceptor: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyDownInterceptor?(event) == true { return }
        super.sendEvent(event)
    }

    /// App 没有 Edit 菜单，⌘A/⌘C/⌘V/⌘X/⌘Z 默认不会被派发，这里手动转给第一响应者
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action: Selector?
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "a"): action = #selector(NSText.selectAll(_:))
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        case (.command, ","): action = #selector(AppDelegate.openSettings(_:))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

extension NSImage {
    /// 可拉伸的圆角蒙版，给 NSVisualEffectView.maskImage 用，窗口阴影也会跟着圆角走
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension NSImage {
    /// 圆形头像：有图片用图片，否则昵称首字 + 强调色底，都没有时用默认人像图标。
    /// 绘制延迟到使用时，深浅色切换后颜色自动更新
    static func avatar(_ image: NSImage?, name: String, size: CGFloat) -> NSImage {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let image {
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                image.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else if let initial {
                Theme.accentNSColor.setFill()
                circle.fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size * 0.45, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let text = NSAttributedString(string: initial, attributes: attributes)
                let textSize = text.size()
                text.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2))
            } else if let symbol = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular).applying(.init(paletteColors: [.white, .tertiaryLabelColor]))) {
                symbol.draw(in: rect)
            }
            NSColor.labelColor.withAlphaComponent(0.1).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
    }
}

/// 圆角色块标签，文字在色块内水平、垂直居中
/// （直接给 NSTextField 设背景时文字贴在顶部，不会垂直居中）
final class BadgeView: NSView {
    private let label: NSTextField

    init(text: String, color: NSColor) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .black
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
    }
}
