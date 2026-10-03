import AppKit

/// 颜色：输入 hex（#3B82F6、#38f、3b82f6）显示 rgb，输入 rgb（rgb(59,130,246)、rgb 59 130 246、59, 130, 246）显示 hex，
/// 都支持透明度；卡片图标是这个颜色的色块，↩ 复制转换结果
final class ColorConverter: BuiltinExtension {
    let id = "builtin.color"
    var name: String { L10n.t("color.name") }
    var description: String { L10n.t("color.description") }
    let icon: (symbol: String, color: NSColor) = ("paintpalette.fill", .systemPink)

    func answers(for text: String) -> [BuiltinAnswer] {
        guard text.count <= 40 else { return [] }
        if let color = RGBAColor(hex: text) {
            let hsl = color.hslString
            return [answer(color, title: color.rgbString, subtitle: "\(color.hexString) · \(hsl)")]
        }
        if let color = RGBAColor(rgb: text) {
            return [answer(color, title: color.hexString, subtitle: "\(color.rgbString) · \(color.hslString)")]
        }
        return []
    }

    private func answer(_ color: RGBAColor, title: String, subtitle: String) -> BuiltinAnswer {
        BuiltinAnswer(extensionID: id, title: title, subtitle: subtitle, copyText: title, icon: color.swatch())
    }
}

struct RGBAColor: Equatable {
    /// 0...255
    let red: Int, green: Int, blue: Int
    /// 0...1
    let alpha: Double

    // 带 # 时 3/4/6/8 位都行；不带 # 时只认 6 位，且必须同时有数字和字母，避免把 123456、facade 当成颜色
    private static let hexPattern = try! NSRegularExpression(pattern: "^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$|^([0-9a-f]{6})$", options: .caseInsensitive)
    // rgb(59, 130, 246)、rgba(59 130 246 / 50%)、rgb 59 130 246、(59, 130, 246)、59, 130, 246、59 130 246
    private static let rgbPattern = try! NSRegularExpression(
        pattern: #"^(rgba?)?\s*(\()?\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*(?:[,/\s]\s*(\d*\.?\d+%?))?\s*(\))?$"#,
        options: .caseInsensitive
    )

    init(red: Int, green: Int, blue: Int, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hex text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let match = Self.hexPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        var digits = Array(text.hasPrefix("#") ? text.dropFirst() : Substring(text))
        if match.range(at: 2).location != NSNotFound {
            guard digits.contains(where: \.isNumber), digits.contains(where: \.isLetter) else { return nil }
        }
        // #38f → #3388ff
        if digits.count <= 4 { digits = digits.flatMap { [$0, $0] } }
        let bytes = stride(from: 0, to: digits.count, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
        guard bytes.count >= 3 else { return nil }
        self.init(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]), alpha: bytes.count == 4 ? Double(bytes[3]) / 255 : 1)
    }

    init?(rgb text: String) {
        // 中文输入法的全角符号
        let text = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
        guard let match = Self.rgbPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let group = { (index: Int) -> String? in Range(match.range(at: index), in: text).map { String(text[$0]) } }
        let hasPrefix = group(1) != nil
        let open = group(2) != nil, close = group(7) != nil
        // 括号要成对；没有 rgb 前缀的裸数字不带透明度，避免 "1 2 3 4" 之类被当成颜色
        guard open == close, hasPrefix || group(6) == nil else { return nil }
        let channels = [3, 4, 5].compactMap { group($0).flatMap(Int.init) }
        guard channels.count == 3, channels.allSatisfy({ $0 <= 255 }) else { return nil }
        var alpha = 1.0
        if let raw = group(6) {
            let value = raw.hasSuffix("%") ? Double(raw.dropLast()).map { $0 / 100 } : Double(raw)
            guard let value, (0...1).contains(value) else { return nil }
            alpha = value
        }
        self.init(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
    }

    private var hasAlpha: Bool { alpha < 1 }

    private static func formatAlpha(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
    }

    var hexString: String {
        let rgb = String(format: "#%02X%02X%02X", red, green, blue)
        return hasAlpha ? rgb + String(format: "%02X", Int((alpha * 255).rounded())) : rgb
    }

    var rgbString: String {
        hasAlpha ? "rgba(\(red), \(green), \(blue), \(Self.formatAlpha(alpha)))" : "rgb(\(red), \(green), \(blue))"
    }

    var hslString: String {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maxValue = max(r, g, b), minValue = min(r, g, b)
        let lightness = (maxValue + minValue) / 2
        let delta = maxValue - minValue
        var hue = 0.0, saturation = 0.0
        if delta > 0 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            switch maxValue {
            case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            case g: hue = (b - r) / delta + 2
            default: hue = (r - g) / delta + 4
            }
            hue *= 60
            if hue < 0 { hue += 360 }
        }
        let hsl = "\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
        return hasAlpha ? "hsla(\(hsl), \(Self.formatAlpha(alpha)))" : "hsl(\(hsl))"
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }

    /// 和其他图标一样大小的圆角色块；半透明时下面垫棋盘格，浅色加一圈细边
    func swatch() -> NSImage {
        let color = nsColor
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 13, yRadius: 13)
            if color.alphaComponent < 1 {
                NSGraphicsContext.saveGraphicsState()
                tile.addClip()
                NSColor.white.setFill()
                rect.fill()
                NSColor(white: 0.8, alpha: 1).setFill()
                let cell: CGFloat = 8
                for row in 0..<8 {
                    for column in 0..<8 where (row + column).isMultiple(of: 2) {
                        NSRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            color.setFill()
            tile.fill()
            NSColor.black.withAlphaComponent(0.1).setStroke()
            tile.lineWidth = 1
            tile.stroke()
            return true
        }
    }
}
