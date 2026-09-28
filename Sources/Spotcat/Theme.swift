import AppKit
import SwiftUI

/// 产品主题色：图标底色、设置窗口选中项与控件、头像底色。AI 对话面板的 CSS（Resources/chat/style.css）
/// 与图标（Resources/Icon/*.svg）里写的是同一个颜色，改色时一并修改
enum Theme {
    /// 系统蓝（与 macOS 文件夹图标同色，自动适配深浅色）
    static let accentNSColor = NSColor.systemBlue
    static let accent = Color(nsColor: accentNSColor)
}
