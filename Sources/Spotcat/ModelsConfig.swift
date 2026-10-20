import Foundation

/// 服务商提供的一个模型：发给接口的 id，以及可选的显示名称
struct ModelEntry: Codable, Equatable, Hashable {
    var id: String
    var title: String

    init(id: String, title: String = "") {
        self.id = id
        self.title = title
    }

    var displayTitle: String { title.isEmpty ? id : title }
}

/// 模型服务商（BYOK，与 Termany 的模型设置同一结构）：接口格式 + 地址 + Key + 该服务商下可用的模型
struct ModelProvider: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        /// Anthropic Messages API（/v1/messages）
        case anthropic
        /// OpenAI 兼容（/v1/chat/completions）
        case openai
    }

    /// 唯一，是「服务商 id/模型 id」引用的前半段，所以不含 "/"
    var id: String
    /// 显示名称
    var name: String
    var kind: Kind
    /// 留空表示该格式的官方地址
    var apiBase: String
    var apiKey: String
    var models: [ModelEntry]

    init(id: String, name: String, kind: Kind, apiBase: String, apiKey: String, models: [ModelEntry]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.apiBase = apiBase
        self.apiKey = apiKey
        self.models = models
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, apiBase, apiKey, models }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        apiBase = try container.decode(String.self, forKey: .apiBase)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        // 0.6 及以前只存模型 id 字符串
        if let entries = try? container.decode([ModelEntry].self, forKey: .models) {
            models = entries
        } else {
            models = try container.decode([String].self, forKey: .models).map { ModelEntry(id: $0) }
        }
    }

    static let defaultBase: [Kind: String] = [
        .anthropic: "https://api.anthropic.com",
        .openai: "https://api.openai.com/v1",
    ]

    /// 拼接规则：
    /// 1. base 已经以 /chat/completions（OpenAI）或 /messages（Anthropic）结尾：原样使用；
    /// 2. base 以任意版本号段结尾（/v1、/v3、/v4、/v1beta，如智谱 https://open.bigmodel.cn/api/coding/paas/v4）：只补后半段；
    /// 3. 否则补 /v1/…（如 https://api.deepseek.com → /v1/chat/completions）
    var endpoint: URL? {
        let base = (apiBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultBase[kind]! : apiBase)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let suffix = kind == .anthropic ? "/messages" : "/chat/completions"
        if base.lowercased().hasSuffix(suffix) { return URL(string: base) }
        if base.range(of: "/v[0-9]+[a-z0-9]*$", options: [.regularExpression, .caseInsensitive]) != nil {
            return URL(string: base + suffix)
        }
        return URL(string: base + "/v1" + suffix)
    }

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct ModelsConfig: Codable, Equatable {
    var providers: [ModelProvider] = []
    /// "服务商 id/模型 id"
    var defaultModel: String = ""
    /// 改过 id 的服务商：旧 id → 新 id。聊天记录、扩展设置里存的旧引用照样能解析
    var providerAliases: [String: String] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case providers, defaultModel, providerAliases }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try container.decodeIfPresent([ModelProvider].self, forKey: .providers) ?? []
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        providerAliases = try container.decodeIfPresent([String: String].self, forKey: .providerAliases) ?? [:]
    }

    struct Preset {
        let id: String
        let label: String
        let kind: ModelProvider.Kind
        let apiBase: String
        let model: ModelEntry
    }

    /// 与 Termany 的预设一致：选中后填好接口格式、地址和一个起始模型
    static let presets: [Preset] = [
        Preset(id: "anthropic", label: "Anthropic", kind: .anthropic, apiBase: "https://api.anthropic.com", model: ModelEntry(id: "claude-opus-5-5", title: "Claude Opus 5.5")),
        Preset(id: "openai", label: "OpenAI", kind: .openai, apiBase: "https://api.openai.com/v1", model: ModelEntry(id: "gpt-5.6-sol", title: "GPT-5.6 Sol")),
        Preset(id: "openrouter", label: "OpenRouter", kind: .openai, apiBase: "https://openrouter.ai/api", model: ModelEntry(id: "xiaomi/mimo-v2.5", title: "MiMo V2.5")),
        Preset(id: "deepseek", label: "DeepSeek", kind: .openai, apiBase: "https://api.deepseek.com", model: ModelEntry(id: "deepseek-v4-flash", title: "DeepSeek V4 Flash")),
        Preset(id: "minimax", label: "MiniMax", kind: .anthropic, apiBase: "https://api.minimax.io/anthropic", model: ModelEntry(id: "MiniMax-M3", title: "MiniMax M3")),
        Preset(id: "glm", label: "Z.AI", kind: .anthropic, apiBase: "https://api.z.ai/api/anthropic", model: ModelEntry(id: "GLM-5.2", title: "GLM-5.2")),
        // 智谱 BigModel（国内站）：OpenAI 兼容，地址以 /v4 结尾
        Preset(id: "zhipu-coding", label: "智谱 GLM Coding Plan", kind: .openai, apiBase: "https://open.bigmodel.cn/api/coding/paas/v4", model: ModelEntry(id: "GLM-5.2", title: "GLM-5.2")),
        Preset(id: "zhipu", label: "智谱 BigModel", kind: .openai, apiBase: "https://open.bigmodel.cn/api/paas/v4", model: ModelEntry(id: "GLM-5.2", title: "GLM-5.2")),
        Preset(id: "custom", label: "", kind: .openai, apiBase: "", model: ModelEntry(id: "")),
    ]

    static func preset(matching provider: ModelProvider) -> Preset? {
        let base = provider.apiBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return presets.first { $0.id != "custom" && $0.apiBase == base && $0.kind == provider.kind }
    }

    static func reference(_ provider: ModelProvider, _ model: ModelEntry) -> String { "\(provider.id)/\(model.id)" }

    var allModels: [(provider: ModelProvider, model: ModelEntry)] {
        providers.flatMap { provider in provider.models.map { (provider, $0) } }
    }

    /// 指定的 "服务商 id/模型 id"；为空或已失效（服务商、模型被删除）时用默认模型。服务商改过 id 时旧引用也能解析
    func resolve(_ id: String?) -> (provider: ModelProvider, model: ModelEntry)? {
        if let id = id.map(canonical), let hit = allModels.first(where: { Self.reference($0.provider, $0.model) == id }) {
            return hit
        }
        return resolvedDefault
    }

    /// 当前默认模型；默认值失效时退回第一个可用模型
    var resolvedDefault: (provider: ModelProvider, model: ModelEntry)? {
        let id = canonical(defaultModel)
        return allModels.first { Self.reference($0.provider, $0.model) == id } ?? allModels.first
    }

    /// 把旧服务商 id 开头的引用换成新 id
    func canonical(_ reference: String) -> String {
        guard let slash = reference.firstIndex(of: "/") else { return reference }
        var providerID = String(reference[..<slash])
        var seen = Set<String>()
        while let next = providerAliases[providerID], seen.insert(providerID).inserted { providerID = next }
        return providerID + reference[slash...]
    }

    /// 让默认模型始终指向还存在的模型
    mutating func normalizeDefault() {
        defaultModel = resolvedDefault.map { Self.reference($0.provider, $0.model) } ?? ""
    }

    /// 服务商改 id：记下别名，默认模型跟着改
    mutating func renameProvider(_ oldID: String, to newID: String) {
        guard oldID != newID, let index = providers.firstIndex(where: { $0.id == oldID }) else { return }
        providers[index].id = newID
        providerAliases[oldID] = newID
        providerAliases[newID] = nil
        if defaultModel.hasPrefix(oldID + "/") {
            defaultModel = newID + defaultModel.dropFirst(oldID.count)
        }
    }

    // MARK: - 校验

    /// 服务商 id：小写字母、数字、"."、"_"、"-"，以字母或数字开头。
    /// 不碰 L10n：迁移在 SettingsStore 初始化期间运行，而 L10n 要读 SettingsStore
    static func isValidProviderID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    static func providerIDProblem(_ id: String, takenBy others: [ModelProvider]) -> String? {
        if id.isEmpty { return L10n.t("models.error.providerIDEmpty") }
        if !isValidProviderID(id) { return L10n.t("models.error.providerIDFormat") }
        if let other = others.first(where: { $0.id == id }) {
            return L10n.t("models.error.providerIDTaken", id, other.name)
        }
        return nil
    }

    /// 模型 id 原样发给接口，只拦空的、带空格的和重复的
    static func modelsProblem(_ models: [ModelEntry]) -> String? {
        if models.isEmpty { return L10n.t("models.error.noModels") }
        var seen = Set<String>()
        for model in models {
            if model.id.isEmpty { return L10n.t("models.error.modelIDEmpty") }
            if model.id.contains(where: \.isWhitespace) { return L10n.t("models.error.modelIDSpace", model.id) }
            if !seen.insert(model.id).inserted { return L10n.t("models.error.modelIDDuplicate", model.id) }
        }
        return nil
    }

    /// 由名称生成一个没被占用的服务商 id，如 "deepseek"、"deepseek-2"
    func uniqueID(for name: String, excluding: String? = nil) -> String {
        let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "provider" : slug
        var candidate = base
        var index = 2
        while providers.contains(where: { $0.id == candidate && $0.id != excluding }) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    /// 0.6 及以前服务商 id 是 UUID：换成由名称生成的可读 id，旧 id 记为别名。返回是否有改动
    mutating func migrateProviderIDs() -> Bool {
        var changed = false
        // UUID 有大写的也有小写的，小写的本身符合 id 规则，要单独认出来
        let uuid = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        for provider in providers
        where !Self.isValidProviderID(provider.id) || provider.id.range(of: uuid, options: .regularExpression) != nil {
            let name = provider.name.isEmpty ? (Self.preset(matching: provider)?.id ?? provider.endpoint?.host ?? "") : provider.name
            renameProvider(provider.id, to: uniqueID(for: name))
            changed = true
        }
        return changed
    }

    // MARK: - 持久化（数据目录/models.json，权限 600）

    private static var fileURL: URL { AppEnvironment.dataDirectory.appendingPathComponent("models.json") }

    static func load() -> ModelsConfig {
        guard let data = try? Data(contentsOf: fileURL), var config = try? JSONDecoder().decode(ModelsConfig.self, from: data) else {
            return ModelsConfig()
        }
        if config.migrateProviderIDs() { config.save() }
        return config
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
