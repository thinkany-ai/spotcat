import Foundation

enum AIError: LocalizedError {
    case notConfigured
    case invalidURL
    case http(Int, String?)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return L10n.t("error.ai.notConfigured")
        case .invalidURL: return "Invalid Base URL"
        case .http(let status, let message): return "HTTP \(status)" + (message.map { ": \($0)" } ?? "")
        case .server(let message): return message
        }
    }
}

/// 调用用户配置的模型，支持 Anthropic Messages 与 OpenAI 兼容两种接口，始终以流式请求。
/// onDelta 为 nil 时只返回完整结果
final class AIService {
    static let shared = AIService()

    /// 使用设置中的默认模型
    @MainActor
    func chat(messages: [[String: String]], onDelta: ((String) -> Void)? = nil) async throws -> String {
        guard let target = SettingsStore.shared.models.resolvedDefault, target.provider.hasKey else {
            throw AIError.notConfigured
        }
        return try await chat(messages: messages, provider: target.provider, model: target.model, onDelta: onDelta)
    }

    @MainActor
    func chat(messages: [[String: String]], provider: ModelProvider, model: String,
              onDelta: ((String) -> Void)? = nil) async throws -> String {
        guard let url = provider.endpoint else { throw AIError.invalidURL }
        let key = provider.apiKey.trimmingCharacters(in: .whitespaces)

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch provider.kind {
        case .openai:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "messages": messages, "stream": true,
            ])
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // Anthropic 的 system 是独立字段，对话里只能有 user / assistant
            let system = messages.filter { $0["role"] == "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 4096,
                "messages": messages.filter { $0["role"] != "system" },
                "stream": true,
            ]
            if !system.isEmpty { body["system"] = system }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 4000 { break }
            }
            throw AIError.http(status, Self.errorMessage(in: body))
        }

        var full = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let message = Self.errorMessage(in: json) { throw AIError.server(message) }

            let text: String?
            switch provider.kind {
            case .openai:
                let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
                text = delta?["content"] as? String
            case .anthropic:
                // content_block_delta 事件里的 text_delta
                let delta = json["delta"] as? [String: Any]
                text = delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
            }
            if let text, !text.isEmpty {
                full += text
                onDelta?(text)
            }
        }
        return full
    }

    /// 设置页「测试连接」：用该服务商的第一个模型发一条极短的请求
    @MainActor
    func test(_ provider: ModelProvider) async throws -> String {
        guard provider.hasKey else { throw AIError.notConfigured }
        guard let model = provider.models.first else { throw AIError.server(L10n.t("models.test.noModel")) }
        let reply = try await chat(messages: [["role": "user", "content": "Reply with the single word: OK"]],
                                   provider: provider, model: model)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func errorMessage(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body.isEmpty ? nil : String(body.prefix(300))
        }
        return errorMessage(in: json)
    }

    private static func errorMessage(in json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] { return error["message"] as? String }
        return json["error"] as? String
    }
}
