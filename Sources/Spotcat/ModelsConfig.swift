import Foundation

/// 模型服务商（BYOK，与 Termany 的模型设置同一结构）：接口格式 + 地址 + Key + 该服务商下可用的模型
struct ModelProvider: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        /// Anthropic Messages API（/v1/messages）
        case anthropic
        /// OpenAI 兼容（/v1/chat/completions）
        case openai
    }

    var id: String
    var name: String
    var kind: Kind
    /// 留空表示该格式的官方地址
    var apiBase: String
    var apiKey: String
    var models: [String]

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
    /// "服务商 id/模型名"
    var defaultModel: String = ""

    struct Preset {
        let id: String
        let label: String
        let kind: ModelProvider.Kind
        let apiBase: String
        let model: String
    }

    /// 与 Termany 的预设一致：选中后填好接口格式、地址和一个起始模型
    static let presets: [Preset] = [
        Preset(id: "anthropic", label: "Anthropic", kind: .anthropic, apiBase: "https://api.anthropic.com", model: "claude-opus-4-8"),
        Preset(id: "openai", label: "OpenAI", kind: .openai, apiBase: "https://api.openai.com/v1", model: "gpt-5.6-sol"),
        Preset(id: "openrouter", label: "OpenRouter", kind: .openai, apiBase: "https://openrouter.ai/api", model: "xiaomi/mimo-v2.5"),
        Preset(id: "deepseek", label: "DeepSeek", kind: .openai, apiBase: "https://api.deepseek.com", model: "deepseek-v4-flash"),
        Preset(id: "minimax", label: "MiniMax", kind: .anthropic, apiBase: "https://api.minimax.io/anthropic", model: "MiniMax-M3"),
        Preset(id: "glm", label: "Z.AI", kind: .anthropic, apiBase: "https://api.z.ai/api/anthropic", model: "GLM-5.2"),
        // 智谱 BigModel（国内站）：OpenAI 兼容，地址以 /v4 结尾
        Preset(id: "zhipu-coding", label: "智谱 GLM Coding Plan", kind: .openai, apiBase: "https://open.bigmodel.cn/api/coding/paas/v4", model: "GLM-5.2"),
        Preset(id: "zhipu", label: "智谱 BigModel", kind: .openai, apiBase: "https://open.bigmodel.cn/api/paas/v4", model: "GLM-5.2"),
        Preset(id: "custom", label: "", kind: .openai, apiBase: "", model: ""),
    ]

    /// 指定的 "服务商 id/模型名"；为空或已失效（服务商、模型被删除）时用默认模型
    func resolve(_ id: String?) -> (provider: ModelProvider, model: String)? {
        if let id, let hit = providers.lazy.flatMap({ p in p.models.map { (p, $0) } }).first(where: { "\($0.0.id)/\($0.1)" == id }) {
            return hit
        }
        return resolvedDefault
    }

    /// 当前默认模型；默认值失效时退回第一个可用模型
    var resolvedDefault: (provider: ModelProvider, model: String)? {
        let all = providers.flatMap { provider in provider.models.map { (provider, $0) } }
        return all.first { "\($0.0.id)/\($0.1)" == defaultModel } ?? all.first
    }

    // MARK: - 持久化（数据目录/models.json，权限 600）

    private static var fileURL: URL { AppEnvironment.dataDirectory.appendingPathComponent("models.json") }

    static func load() -> ModelsConfig {
        if let data = try? Data(contentsOf: fileURL), let config = try? JSONDecoder().decode(ModelsConfig.self, from: data) {
            return config
        }
        return ModelsConfig()
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
