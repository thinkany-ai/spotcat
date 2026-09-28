import Foundation

enum SearchText {
    /// "网易云音乐" -> "wang yi yun yin le"；纯 ASCII 返回 nil
    static func pinyin(of text: String) -> String? {
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return nil }
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let result = mutable as String
        return result == text ? nil : result
    }

    /// 原文 + 含中文时的拼音
    static func keys(for text: String) -> [String] {
        [text] + (pinyin(of: text).map { [$0] } ?? [])
    }
}
