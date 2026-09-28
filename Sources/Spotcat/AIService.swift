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

/// OpenAI 兼容的 /chat/completions，始终以流式（SSE）请求，onDelta 为 nil 时只返回完整结果
final class AIService {
    static let shared = AIService()

    @MainActor
    func chat(messages: [[String: String]], onDelta: ((String) -> Void)? = nil) async throws -> String {
        let config = SettingsStore.shared.ai
        guard config.isConfigured else { throw AIError.notConfigured }

        let base = config.baseURL.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: base + "/chat/completions") else { throw AIError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model.trimmingCharacters(in: .whitespaces),
            "messages": messages,
            "stream": true,
        ])

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

            let choices = json["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            if let content = delta?["content"] as? String, !content.isEmpty {
                full += content
                onDelta?(content)
            }
        }
        return full
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
