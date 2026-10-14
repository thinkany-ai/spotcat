import AppKit

/// Bottom shelf geometry uses the visible frame, so the Dock, menu bar and negative-origin displays are respected.
enum ClipboardShelfLayout {
    static func frame(in visible: CGRect) -> CGRect {
        let margin: CGFloat = min(12, min(visible.width, visible.height) / 8)
        let width = max(1, min(1440, visible.width - margin * 2))
        let height = max(1, min(520, visible.height - margin * 2))
        return CGRect(x: visible.midX - width / 2, y: visible.minY + margin, width: width, height: height)
    }
}
