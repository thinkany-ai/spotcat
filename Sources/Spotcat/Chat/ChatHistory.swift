import Foundation

/// AI 对话历史：每个对话一个 JSON 文件，数据目录/Chats/<id>.json。
/// 对话内容由聊天页面（Resources/chat/main.js）决定，这里只要求有 id、title、updatedAt
enum ChatHistory {
    static var directory: URL {
        AppEnvironment.dataDirectory.appendingPathComponent("Chats", isDirectory: true)
    }

    /// 列表只返回摘要，新的在前
    static func list() -> [[String: Any]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { read($0) }
            .map { chat in
                var summary: [String: Any] = [:]
                for key in ["id", "title", "updatedAt"] { summary[key] = chat[key] }
                // 搜索用：所有消息拼起来（截断，避免列表过大）
                let text = (chat["messages"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }.joined(separator: "\n")
                summary["text"] = String(text.prefix(4000))
                return summary
            }
            .sorted { ($0["updatedAt"] as? Double ?? 0) > ($1["updatedAt"] as? Double ?? 0) }
    }

    static func get(id: String) -> [String: Any]? {
        guard let url = url(for: id) else { return nil }
        return read(url)
    }

    static func save(_ chat: [String: Any]) throws {
        guard let id = chat["id"] as? String, let url = url(for: id) else {
            throw NSError(domain: "Spotcat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid chat id"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: chat)
        try data.write(to: url, options: .atomic)
    }

    static func delete(id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// id 只允许字母、数字和连字符，防止写到目录外
    private static func url(for id: String) -> URL? {
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return directory.appendingPathComponent("\(id).json")
    }

    private static func read(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
