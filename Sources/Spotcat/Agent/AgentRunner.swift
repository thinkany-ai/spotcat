import Foundation

/// AI 对话的 agent loop：请求模型 → 执行它要调用的本机工具 → 把结果发回去，直到模型给出最终回答。
/// 工具在本机执行（AgentTools），模型只看到工具返回的文本
@MainActor
final class AgentRunner {
    /// 最多几轮工具调用；超过后不带工具再请求一次，让模型基于已有结果作答
    static let maxRounds = 12

    /// 不支持工具调用的模型（请求带 tools 时报错），本次运行期间直接按普通对话处理
    private static var modelsWithoutTools = Set<String>()

    /// 推给页面的事件：
    /// { type: "text", delta } 回复文字增量
    /// { type: "tool_start", call_id, name, arguments } 开始执行工具（arguments 为解析后的对象）
    /// { type: "tool_end", call_id, output, is_error } 工具执行完（output 为给页面展示的截断结果）
    typealias EventHandler = ([String: Any]) -> Void

    /// 运行一次回复，返回本次新增的消息（assistant / tool，与服务商无关的格式），页面存进历史，下一轮原样带上
    func run(messages: [[String: Any]], model: String?, onEvent: @escaping EventHandler) async throws -> [[String: Any]] {
        guard let target = SettingsStore.shared.models.resolve(model), target.provider.hasKey else {
            throw AIError.notConfigured
        }
        let modelKey = "\(target.provider.id)/\(target.model)"
        var conversation = Self.withToolGuide(messages)
        var added: [[String: Any]] = []
        let emitText: (String) -> Void = { onEvent(["type": "text", "delta": $0]) }

        for round in 0...Self.maxRounds {
            let useTools = round < Self.maxRounds && !Self.modelsWithoutTools.contains(modelKey)
            let turn: AIService.Turn
            do {
                turn = try await AIService.shared.turn(
                    messages: conversation, tools: useTools ? AgentTools.all : nil,
                    provider: target.provider, model: target.model, onText: emitText
                )
            } catch let error as AIError where useTools && added.isEmpty && Self.isToolsUnsupported(error) {
                // 模型不支持工具：记下来，按普通对话重试
                NSLog("%@", "Spotcat: \(modelKey) 不支持工具调用，按普通对话处理（\(error.localizedDescription)）")
                Self.modelsWithoutTools.insert(modelKey)
                turn = try await AIService.shared.turn(
                    messages: Self.stripToolGuide(conversation), tools: nil,
                    provider: target.provider, model: target.model, onText: emitText
                )
            }

            conversation.append(turn.message)
            added.append(turn.message)
            guard !turn.toolCalls.isEmpty else { break }

            for call in turn.toolCalls {
                try Task.checkCancellation()
                let arguments = call.arguments.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                onEvent(["type": "tool_start", "call_id": call.id, "name": call.name, "arguments": arguments])

                var output: String
                var isError = false
                do {
                    // 文件读取和 Spotlight 查询放到后台线程
                    output = try await Task.detached(priority: .userInitiated) {
                        try AgentTools.run(name: call.name, arguments: arguments)
                    }.value
                } catch {
                    output = "Error: \(error.localizedDescription)"
                    isError = true
                }
                onEvent(["type": "tool_end", "call_id": call.id, "output": String(output.prefix(4000)), "is_error": isError])

                var result: [String: Any] = ["role": "tool", "tool_call_id": call.id, "name": call.name, "content": output]
                if isError { result["is_error"] = true }
                conversation.append(result)
                added.append(result)
            }
        }
        return added
    }

    // MARK: - 系统提示

    private static let guideMarker = "\n\n## Tools\n"

    /// 在 system 消息后面补上工具说明和本机信息
    private static func withToolGuide(_ messages: [[String: Any]]) -> [[String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let guide = guideMarker + """
        You are running inside Spotcat on the user's Mac and can use tools to look at their files \
        (list directories, search with Spotlight, read text and PDF files). These tools are read-only. \
        When the user asks about their files or folders, use the tools instead of saying you cannot access them. \
        Home directory: \(home) (write it as ~). Current local time: \(formatter.string(from: Date())). \
        Show paths with ~ and keep answers focused on what the user asked.
        """
        var messages = messages
        if let index = messages.firstIndex(where: { $0["role"] as? String == "system" }) {
            messages[index]["content"] = (messages[index]["content"] as? String ?? "") + guide
        } else {
            messages.insert(["role": "system", "content": String(guide.dropFirst(2))], at: 0)
        }
        return messages
    }

    private static func stripToolGuide(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            guard message["role"] as? String == "system", let content = message["content"] as? String,
                  let range = content.range(of: guideMarker) else { return message }
            var message = message
            message["content"] = String(content[..<range.lowerBound])
            return message
        }
    }

    /// 400/422/404 且报错里提到 tool / function，视为模型不支持工具调用
    private static func isToolsUnsupported(_ error: AIError) -> Bool {
        guard case .http(let status, let message) = error, [400, 404, 422].contains(status) else { return false }
        let text = (message ?? "").lowercased()
        return text.contains("tool") || text.contains("function")
    }
}
