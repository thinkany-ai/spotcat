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

    /// model 为 "服务商 id/模型名"，不传或失效时使用设置中的默认模型
    @MainActor
    func chat(messages: [[String: String]], model: String? = nil, onDelta: ((String) -> Void)? = nil) async throws -> String {
        guard let target = SettingsStore.shared.models.resolve(model), target.provider.hasKey else {
            throw AIError.notConfigured
        }
        return try await chat(messages: messages, provider: target.provider, model: target.model, onDelta: onDelta)
    }

    @MainActor
    func chat(messages: [[String: String]], provider: ModelProvider, model: String,
              onDelta: ((String) -> Void)? = nil) async throws -> String {
        try await turn(messages: messages, tools: nil, provider: provider, model: model, onText: onDelta).text
    }

    // MARK: - 单轮请求（支持工具调用）

    /// 模型请求调用的工具
    struct ToolCall {
        let id: String
        let name: String
        /// 原始 JSON 字符串（流式拼接而来，可能不完整）
        let arguments: String
    }

    /// 一轮回复：文字 + 工具调用。reasoning / thinking 是部分服务商的推理内容，
    /// 同一轮工具调用往返时需要原样带回（DeepSeek 的 reasoning_content、Anthropic 的 thinking 块）
    struct Turn {
        var text = ""
        var toolCalls: [ToolCall] = []
        var reasoning = ""
        var thinking: [[String: Any]] = []

        /// 转成与服务商无关的消息，存进对话历史
        var message: [String: Any] {
            var message: [String: Any] = ["role": "assistant", "content": text]
            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls.map { ["id": $0.id, "name": $0.name, "arguments": $0.arguments] }
            }
            if !reasoning.isEmpty { message["reasoning"] = reasoning }
            if !thinking.isEmpty { message["thinking"] = thinking }
            return message
        }
    }

    /// 发送一轮请求并流式读取回复。messages 是与服务商无关的格式：
    /// system / user：{ role, content }；assistant：{ role, content, tool_calls?: [{ id, name, arguments }], reasoning?, thinking? }；
    /// tool：{ role: "tool", tool_call_id, name, content, is_error? }。tools 为 nil 时不带工具
    @MainActor
    func turn(messages: [[String: Any]], tools: [AgentTools.Tool]?, provider: ModelProvider, model: String,
              onText: ((String) -> Void)? = nil) async throws -> Turn {
        guard let url = provider.endpoint else { throw AIError.invalidURL }
        let key = provider.apiKey.trimmingCharacters(in: .whitespaces)

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch provider.kind {
        case .openai:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var body: [String: Any] = ["model": model, "messages": Self.openAIMessages(messages), "stream": true]
            if let tools, !tools.isEmpty {
                body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] }
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // Anthropic 的 system 是独立字段，对话里只能有 user / assistant
            let system = messages.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n\n")
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 8192,
                "messages": Self.anthropicMessages(messages),
                "stream": true,
            ]
            if !system.isEmpty { body["system"] = system }
            if let tools, !tools.isEmpty {
                body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
            }
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

        var turn = Turn()
        // 流式的工具调用按下标拼接：OpenAI 用 tool_calls[].index，Anthropic 用 content block 的 index
        var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        var thinking: [Int: [String: Any]] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let message = Self.errorMessage(in: json) { throw AIError.server(message) }

            var text: String?
            switch provider.kind {
            case .openai:
                let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
                text = delta?["content"] as? String
                if let reasoning = (delta?["reasoning_content"] ?? delta?["reasoning"]) as? String { turn.reasoning += reasoning }
                for call in delta?["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = (call["index"] as? NSNumber)?.intValue ?? 0
                    let function = call["function"] as? [String: Any]
                    var entry = calls[index] ?? (id: "", name: "", arguments: "")
                    if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                    if let name = function?["name"] as? String, !name.isEmpty { entry.name = name }
                    entry.arguments += function?["arguments"] as? String ?? ""
                    calls[index] = entry
                }
            case .anthropic:
                let index = (json["index"] as? NSNumber)?.intValue ?? 0
                switch json["type"] as? String {
                case "content_block_start":
                    let block = json["content_block"] as? [String: Any] ?? [:]
                    switch block["type"] as? String {
                    case "tool_use":
                        calls[index] = (id: block["id"] as? String ?? "", name: block["name"] as? String ?? "", arguments: "")
                    case "thinking", "redacted_thinking":
                        thinking[index] = block
                    default: break
                    }
                case "content_block_delta":
                    let delta = json["delta"] as? [String: Any] ?? [:]
                    switch delta["type"] as? String {
                    case "text_delta": text = delta["text"] as? String
                    case "input_json_delta": calls[index]?.arguments += delta["partial_json"] as? String ?? ""
                    case "thinking_delta", "signature_delta":
                        let field = delta["type"] as? String == "thinking_delta" ? "thinking" : "signature"
                        if var block = thinking[index] {
                            block[field] = (block[field] as? String ?? "") + (delta[field] as? String ?? "")
                            thinking[index] = block
                        }
                    default: break
                    }
                default: break
                }
            }
            if let text, !text.isEmpty {
                turn.text += text
                onText?(text)
            }
        }
        turn.toolCalls = calls.sorted { $0.key < $1.key }.map { _, call in
            ToolCall(id: call.id.isEmpty ? "call_" + UUID().uuidString.prefix(8) : call.id, name: call.name, arguments: call.arguments)
        }
        turn.thinking = thinking.sorted { $0.key < $1.key }.map(\.value)
        return turn
    }

    private static func openAIMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            switch message["role"] as? String {
            case "assistant":
                var result: [String: Any] = ["role": "assistant"]
                let text = message["content"] as? String ?? ""
                let calls = message["tool_calls"] as? [[String: Any]] ?? []
                result["content"] = text.isEmpty && !calls.isEmpty ? NSNull() : text
                if !calls.isEmpty {
                    result["tool_calls"] = calls.map { call in
                        ["id": call["id"] ?? "", "type": "function",
                         "function": ["name": call["name"] ?? "", "arguments": call["arguments"] as? String ?? "{}"]]
                    }
                }
                if let reasoning = message["reasoning"] as? String, !reasoning.isEmpty { result["reasoning_content"] = reasoning }
                return result
            case "tool":
                return ["role": "tool", "tool_call_id": message["tool_call_id"] ?? "", "content": message["content"] ?? ""]
            default:
                return ["role": message["role"] ?? "user", "content": message["content"] ?? ""]
            }
        }
    }

    /// 连续的工具结果合并成一条 user 消息（tool_result 块）
    private static func anthropicMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for message in messages {
            switch message["role"] as? String {
            case "system":
                continue
            case "assistant":
                var blocks: [[String: Any]] = message["thinking"] as? [[String: Any]] ?? []
                if let text = message["content"] as? String, !text.isEmpty { blocks.append(["type": "text", "text": text]) }
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let input = (call["arguments"] as? String)?.data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    blocks.append(["type": "tool_use", "id": call["id"] ?? "", "name": call["name"] ?? "", "input": input])
                }
                if blocks.isEmpty { blocks.append(["type": "text", "text": "…"]) }
                result.append(["role": "assistant", "content": blocks])
            case "tool":
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": message["tool_call_id"] ?? "", "content": message["content"] ?? ""]
                if message["is_error"] as? Bool == true { block["is_error"] = true }
                if var last = result.last, last["role"] as? String == "user", var content = last["content"] as? [[String: Any]],
                   content.first?["type"] as? String == "tool_result" {
                    content.append(block)
                    last["content"] = content
                    result[result.count - 1] = last
                } else {
                    result.append(["role": "user", "content": [block]])
                }
            default:
                result.append(["role": "user", "content": message["content"] ?? ""])
            }
        }
        return result
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
