import Foundation

// Endpoint tests must not touch a user's model settings or API keys.
enum AppEnvironment {
    static var dataDirectory: URL { fatalError("Model endpoint tests must not access persisted settings") }
}

enum L10n {
    static func t(_ key: String, _ args: CVarArg...) -> String { key }
}

struct EndpointCase {
    let name: String
    let kind: ModelProvider.Kind
    let base: String
    let expected: String
}

let cases: [EndpointCase] = [
    .init(name: "default OpenAI", kind: .openai, base: "", expected: "https://api.openai.com/v1/chat/completions"),
    .init(name: "whitespace-only default", kind: .openai, base: " \n\t ", expected: "https://api.openai.com/v1/chat/completions"),
    .init(name: "default Anthropic", kind: .anthropic, base: "", expected: "https://api.anthropic.com/v1/messages"),
    .init(name: "explicit v1", kind: .openai, base: "https://api.openai.com/v1", expected: "https://api.openai.com/v1/chat/completions"),
    .init(name: "DeepSeek unversioned", kind: .openai, base: "https://api.deepseek.com", expected: "https://api.deepseek.com/v1/chat/completions"),
    .init(name: "OpenRouter API prefix", kind: .openai, base: "https://openrouter.ai/api", expected: "https://openrouter.ai/api/v1/chat/completions"),
    .init(name: "Zhipu Coding Plan v4", kind: .openai, base: "https://open.bigmodel.cn/api/coding/paas/v4", expected: "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"),
    .init(name: "Zhipu standard v4", kind: .openai, base: "https://open.bigmodel.cn/api/paas/v4", expected: "https://open.bigmodel.cn/api/paas/v4/chat/completions"),
    .init(name: "trim whitespace and trailing slashes", kind: .openai, base: " \nhttps://open.bigmodel.cn/api/coding/paas/v4///\t\n", expected: "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"),
    .init(name: "complete non-v1 endpoint", kind: .openai, base: "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions", expected: "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"),
    .init(name: "complete unversioned endpoint", kind: .openai, base: "https://example.com/custom/chat/completions/", expected: "https://example.com/custom/chat/completions"),
    .init(name: "complete v1 endpoint", kind: .openai, base: "https://api.openai.com/v1/chat/completions", expected: "https://api.openai.com/v1/chat/completions"),
    .init(name: "v3 endpoint", kind: .openai, base: "https://example.com/api/v3", expected: "https://example.com/api/v3/chat/completions"),
    .init(name: "beta version endpoint", kind: .openai, base: "https://example.com/api/v1beta", expected: "https://example.com/api/v1beta/chat/completions"),
    .init(name: "version with beta number", kind: .openai, base: "https://example.com/api/v2beta1", expected: "https://example.com/api/v2beta1/chat/completions"),
    .init(name: "uppercase version", kind: .openai, base: "https://example.com/api/V4", expected: "https://example.com/api/V4/chat/completions"),
    .init(name: "version only matches final segment", kind: .openai, base: "https://example.com/v4/proxy", expected: "https://example.com/v4/proxy/v1/chat/completions"),
    .init(name: "version requires a numeric suffix", kind: .openai, base: "https://example.com/api/vendor", expected: "https://example.com/api/vendor/v1/chat/completions"),
    .init(name: "Anthropic v1", kind: .anthropic, base: "https://api.anthropic.com/v1", expected: "https://api.anthropic.com/v1/messages"),
    .init(name: "complete Anthropic endpoint", kind: .anthropic, base: "https://example.com/custom/messages", expected: "https://example.com/custom/messages"),
    .init(name: "versioned Anthropic proxy", kind: .anthropic, base: "https://example.com/proxy/v4", expected: "https://example.com/proxy/v4/messages"),
    .init(name: "MiniMax proxy", kind: .anthropic, base: "https://api.minimax.io/anthropic", expected: "https://api.minimax.io/anthropic/v1/messages"),
    .init(name: "Z.AI proxy", kind: .anthropic, base: "https://api.z.ai/api/anthropic", expected: "https://api.z.ai/api/anthropic/v1/messages"),
]

var failures = 0
for test in cases {
    let provider = ModelProvider(id: "fixture", name: "Fixture", kind: test.kind, apiBase: test.base, apiKey: "", models: [])
    if provider.endpoint?.absoluteString == test.expected {
        print("PASS: \(test.name)")
    } else {
        failures += 1
        print("FAIL: \(test.name): expected \(test.expected), got \(provider.endpoint?.absoluteString ?? "nil")")
    }
}

for id in ["zhipu-coding", "zhipu"] {
    guard let preset = ModelsConfig.presets.first(where: { $0.id == id }) else {
        failures += 1
        print("FAIL: missing \(id) preset")
        continue
    }
    let provider = ModelProvider(id: "fixture", name: preset.label, kind: preset.kind, apiBase: preset.apiBase, apiKey: "", models: [preset.model])
    if preset.kind == .openai && !preset.model.id.isEmpty && provider.endpoint?.absoluteString == preset.apiBase + "/chat/completions" {
        print("PASS: \(id) preset")
    } else {
        failures += 1
        print("FAIL: \(id) preset is inconsistent")
    }
}
print("\(cases.count + 2) endpoint/preset checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
