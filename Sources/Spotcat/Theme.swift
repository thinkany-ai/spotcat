import AppKit
import SwiftUI

/// 产品主题色：图标底色、设置窗口选中项与控件、头像底色。AI 对话面板的 CSS（Resources/chat/style.css）
/// 与图标（Resources/Icon/*.svg）里写的是同一个颜色，改色时一并修改
enum Theme {
    /// 珊瑚红：浅色 #F65E6A，深色 #FF6F7A
    static let accentNSColor = NSColor(name: "SpotcatAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0x6F / 255, blue: 0x7A / 255, alpha: 1)
            : NSColor(srgbRed: 0xF6 / 255, green: 0x5E / 255, blue: 0x6A / 255, alpha: 1)
    }
    static let accent = Color(nsColor: accentNSColor)
}
