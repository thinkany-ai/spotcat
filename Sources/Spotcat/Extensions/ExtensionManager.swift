import AppKit

/// 已加载的扩展
final class SpotcatExtension {
    /// 已本地化的 manifest
    let manifest: ExtensionManifest
    let directory: URL
    let isBuiltIn: Bool
    let features: [ExtensionFeatureRef]
    /// 页面使用的语言和文案（注入到 spotcat.i18n）
    let l10n: LocaleMessages

    var id: String { manifest.id }
    var mainURL: URL { directory.appendingPathComponent(manifest.main ?? "index.html") }

    init(manifest raw: ExtensionManifest, directory: URL, isBuiltIn: Bool) {
        l10n = LocaleMessages(directory: directory, defaultLocale: raw.defaultLocale ?? "en")
        let manifest = raw.localized(with: l10n)
        self.manifest = manifest
        self.directory = directory
        self.isBuiltIn = isBuiltIn
        features = manifest.features.map { ExtensionFeatureRef(extensionID: manifest.id, feature: $0) }
    }
}

/// 扩展里的一个功能，连同预编译好的匹配规则
final class ExtensionFeatureRef {
    let extensionID: String
    let feature: FeatureManifest
    let searchKeys: [String]
    /// 小写、去空白的关键词，用于判断「输入的就是关键词」
    private let normalizedKeys: [String]
    private let rules: [CompiledRule]

    var id: String { "ext:\(extensionID)/\(feature.code)" }

    init(extensionID: String, feature: FeatureManifest) {
        self.extensionID = extensionID
        self.feature = feature
        searchKeys = ([feature.title] + (feature.keywords ?? [])).flatMap(SearchText.keys(for:))
        normalizedKeys = searchKeys.map { String($0.lowercased().filter { !$0.isWhitespace }) }
        rules = (feature.matches ?? []).compactMap(CompiledRule.init)
    }

    var hasMatchRules: Bool { !rules.isEmpty }

    /// query 已小写、去空白
    func isKeyword(_ query: String) -> Bool {
        !query.isEmpty && normalizedKeys.contains { $0.hasPrefix(query) }
    }

    func matches(_ text: String) -> Bool {
        rules.contains { $0.matches(text) }
    }
}

private struct CompiledRule {
    let rule: MatchRule
    let regex: NSRegularExpression?

    init?(_ rule: MatchRule) {
        self.rule = rule
        switch rule.type {
        case .regex:
            guard let pattern = rule.pattern, let regex = try? NSRegularExpression(pattern: pattern) else {
                NSLog("%@", "Spotcat: 无效的匹配正则 \(rule.pattern ?? "nil")")
                return nil
            }
            self.regex = regex
        case .text:
            regex = nil
        }
    }

    func matches(_ text: String) -> Bool {
        let length = text.count
        if length < (rule.minLength ?? 1) { return false }
        if let max = rule.maxLength, length > max { return false }
        guard let regex else { return true }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// 加载内置扩展（App 包内 Resources/Extensions）和用户扩展
/// （~/Library/Application Support/Spotcat/Extensions），用户扩展不能覆盖内置扩展的 id。
/// 搜索面板和设置窗口共用同一个实例
final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    @Published private(set) var extensions: [SpotcatExtension] = []
    private var lastLoad = Date.distantPast

    static var userExtensionsDirectory: URL {
        AppEnvironment.dataDirectory.appendingPathComponent("Extensions", isDirectory: true)
    }

    private static var builtInDirectory: URL? {
        if let root = AppEnvironment.sourceRoot {
            return root.appendingPathComponent("extensions", isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("Extensions", isDirectory: true)
    }

    /// 所有功能（含已禁用的），设置页使用
    var allFeatures: [ExtensionFeatureRef] {
        extensions.flatMap(\.features)
    }

    /// 参与搜索的功能：扩展和功能本身都未被禁用
    var enabledFeatures: [ExtensionFeatureRef] {
        let settings = SettingsStore.shared
        return allFeatures.filter(settings.isFeatureEnabled)
    }

    /// 仅返回启用的功能（「最近使用」里不显示已禁用的）
    func feature(id: String) -> ExtensionFeatureRef? {
        enabledFeatures.first { $0.id == id }
    }

    func owner(of feature: ExtensionFeatureRef) -> SpotcatExtension? {
        extensions.first { $0.id == feature.extensionID }
    }

    /// 同步加载：只读几个 manifest.json，开销很小；间隔内重复调用直接返回，方便开发扩展时改完即生效
    func reloadIfNeeded(maxAge: TimeInterval = 5) {
        guard Date().timeIntervalSince(lastLoad) > maxAge else { return }
        reload()
    }

    /// 语言切换时需要立即重新加载
    func reload() {
        lastLoad = Date()

        try? FileManager.default.createDirectory(at: Self.userExtensionsDirectory, withIntermediateDirectories: true)

        var loaded: [SpotcatExtension] = []
        var ids = Set<String>()
        let sources: [(URL?, Bool)] = [(Self.builtInDirectory, true), (Self.userExtensionsDirectory, false)]
        for (directory, isBuiltIn) in sources {
            guard let directory else { continue }
            for ext in Self.load(from: directory, isBuiltIn: isBuiltIn) {
                guard ids.insert(ext.id).inserted else {
                    NSLog("%@", "Spotcat: 扩展 id 重复，已忽略 \(ext.directory.path)")
                    continue
                }
                loaded.append(ext)
            }
        }
        extensions = loaded
    }

    private static func load(from directory: URL, isBuiltIn: Bool) -> [SpotcatExtension] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { dir in
            // 用户目录里常用软链接指向开发中的扩展
            let dir = dir.resolvingSymlinksInPath()
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            do {
                let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: data)
                return SpotcatExtension(manifest: manifest, directory: dir, isBuiltIn: isBuiltIn)
            } catch {
                NSLog("%@", "Spotcat: 解析 \(manifestURL.path) 失败：\(error)")
                return nil
            }
        }
    }
}
