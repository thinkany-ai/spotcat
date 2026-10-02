import Foundation

/// 扩展目录下的 manifest.json。字段说明见 spotcat-extensions 仓库的 docs/development.md
/// name / description / title / keywords 可写成 "__MSG_key__"，从 locales/<语言>.json 取文案
struct ExtensionManifest: Decodable {
    let id: String
    var name: String
    let version: String
    var description: String?
    let author: String?
    /// "sf:<SF Symbol 名>" 或相对扩展目录的图片路径（png/icns/pdf）
    let icon: String?
    /// 用 SF Symbol 做图标时的背景色，如 "#3B82F6"
    let iconColor: String?
    /// 入口页面，相对扩展目录，默认 index.html
    let main: String?
    /// 需要的敏感能力："network"（spotcat.fetch）、"ai"（spotcat.ai，使用用户的 AI 额度）、"clipboard"（spotcat.clipboard，剪贴板历史）
    let permissions: [String]?
    /// 默认语言，locales/<语言>.json 缺失的文案从这里取
    let defaultLocale: String?
    var features: [FeatureManifest]
}

enum ExtensionPermission: String {
    case network
    case ai
    case clipboard
}

extension ExtensionManifest {
    /// 把 "__MSG_key__" 替换成当前语言的文案；关键词展开为所有语言，任何语言输入都能搜到
    func localized(with l10n: LocaleMessages) -> ExtensionManifest {
        var copy = self
        copy.name = l10n.resolve(name)
        copy.description = description.map(l10n.resolve)
        copy.features = features.map { feature in
            var f = feature
            f.title = l10n.resolve(feature.title)
            f.description = feature.description.map(l10n.resolve)
            f.keywords = feature.keywords?.flatMap(l10n.resolveAll)
            return f
        }
        return copy
    }
}

struct FeatureManifest: Decodable {
    let code: String
    var title: String
    var description: String?
    /// 可选，覆盖扩展图标
    let icon: String?
    let iconColor: String?
    /// 关键词：输入命中时出现在「最佳搜索结果」
    var keywords: [String]?
    /// 内容匹配：输入的内容符合规则时出现在「匹配推荐」
    let matches: [MatchRule]?
}

struct MatchRule: Decodable {
    enum Kind: String, Decodable {
        /// 正则匹配（NSRegularExpression 语法）
        case regex
        /// 任意文本，只受长度限制
        case text
    }

    let type: Kind
    let pattern: String?
    let minLength: Int?
    let maxLength: Int?
}

/// 进入功能的方式，会原样传给扩展
enum EnterTrigger: String {
    /// 通过关键词进入，payload 为用户输入的关键词
    case keyword
    /// 通过内容匹配进入，payload 为匹配到的内容
    case match
    /// 从主搜索框里扩展提供的条目（spotcat.search.setItems）进入，payload 为条目 id
    case item
}
