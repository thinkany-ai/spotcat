import Foundation
import PDFKit

/// AI 对话可调用的本机工具。目前都是只读的：列目录、搜文件、读文件，自动执行、不需要确认。
/// 结果以纯文本返回给模型，超长时截断，避免对话历史过大
enum AgentTools {
    struct Tool {
        let name: String
        let description: String
        /// JSON Schema（object）
        let parameters: [String: Any]
    }

    static let all: [Tool] = [
        Tool(
            name: "list_directory",
            description: "List the files and folders in a directory on the user's Mac, newest first, with type, size and modification time. Use ~ for the home directory, e.g. ~/Downloads, ~/Desktop, ~/Documents.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Directory path, absolute or starting with ~"],
                    "include_hidden": ["type": "boolean", "description": "Include hidden files (default false)"],
                ],
                "required": ["path"],
            ]
        ),
        Tool(
            name: "search_files",
            description: "Search files on the user's Mac with Spotlight. Matches file names (or file contents when match is \"content\"), optionally limited to a folder, file extensions and recent modification. Returns up to 50 results, newest first.",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text to look for in file names or contents. May be empty when filtering only by extension or date."],
                    "match": ["type": "string", "enum": ["name", "content"], "description": "Match file names (default) or file contents"],
                    "directory": ["type": "string", "description": "Only search inside this folder (default: home directory)"],
                    "extensions": ["type": "array", "items": ["type": "string"], "description": "Only files with these extensions, e.g. [\"pdf\", \"docx\"]"],
                    "modified_within_days": ["type": "integer", "description": "Only files modified in the last N days"],
                ],
            ]
        ),
        Tool(
            name: "read_file",
            description: "Read the text of a file on the user's Mac: plain text, code, Markdown, JSON, CSV and similar, or the text of a PDF. Long files are truncated.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path, absolute or starting with ~"],
                ],
                "required": ["path"],
            ]
        ),
    ]

    /// 每个工具结果最多返回给模型的字符数
    static let maxResultLength = 20_000

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 执行工具，返回给模型的文本；在后台线程调用
    static func run(name: String, arguments: [String: Any]) throws -> String {
        let result: String
        switch name {
        case "list_directory": result = try listDirectory(arguments)
        case "search_files": result = try searchFiles(arguments)
        case "read_file": result = try readFile(arguments)
        default: throw ToolError(message: "Unknown tool \(name)")
        }
        guard result.count > maxResultLength else { return result }
        return String(result.prefix(maxResultLength)) + "\n…(truncated)"
    }

    // MARK: - 工具实现

    private static func listDirectory(_ args: [String: Any]) throws -> String {
        let url = try resolve(args["path"])
        let includeHidden = args["include_hidden"] as? Bool ?? false
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: includeHidden ? [] : [.skipsHiddenFiles]
            )
        } catch {
            throw ToolError(message: "Cannot read \(display(url)): \(error.localizedDescription)")
        }
        let rows = entries.map { entry -> (URL, URLResourceValues?) in (entry, try? entry.resourceValues(forKeys: Set(keys))) }
            .sorted { ($0.1?.contentModificationDate ?? .distantPast) > ($1.1?.contentModificationDate ?? .distantPast) }
        let limit = 300
        var lines = ["\(display(url)) — \(entries.count) item(s)" + (entries.count > limit ? ", showing newest \(limit)" : "")]
        for (entry, values) in rows.prefix(limit) {
            lines.append(describe(entry, values))
        }
        return lines.joined(separator: "\n")
    }

    private static func searchFiles(_ args: [String: Any]) throws -> String {
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let byContent = (args["match"] as? String) == "content"
        let directory = try (args["directory"] as? String).map { try resolve($0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let extensions = (args["extensions"] as? [String] ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
        let days = (args["modified_within_days"] as? NSNumber)?.intValue

        // Spotlight 查询语法：c 忽略大小写，d 忽略变音符号，w 按词匹配
        var clauses: [String] = []
        if !query.isEmpty {
            let q = escapeQuery(query)
            clauses.append(byContent ? "kMDItemTextContent == \"\(q)*\"cdw" : "kMDItemFSName == \"*\(q)*\"cd")
        }
        if !extensions.isEmpty {
            clauses.append("(" + extensions.map { "kMDItemFSName == \"*.\(escapeQuery($0))\"c" }.joined(separator: " || ") + ")")
        }
        if let days, days > 0 {
            clauses.append("kMDItemFSContentChangeDate >= $time.today(-\(days))")
        }
        guard !clauses.isEmpty else { throw ToolError(message: "Provide a query, extensions or modified_within_days") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", directory.path, clauses.joined(separator: " && ")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // 宽泛的查询可能返回很多结果，只读前一部分
        let data = pipe.fileHandleForReading.readData(ofLength: 400_000)
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path + "/"
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        let paths = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(library) }
        let results = paths.prefix(500).map { URL(fileURLWithPath: $0) }
            .map { ($0, try? $0.resourceValues(forKeys: keys)) }
            .sorted { ($0.1?.contentModificationDate ?? .distantPast) > ($1.1?.contentModificationDate ?? .distantPast) }
        guard !results.isEmpty else { return "No files found in \(display(directory))." }
        let limit = 50
        var lines = ["\(results.count)\(paths.count > results.count ? "+" : "") result(s) in \(display(directory))" + (results.count > limit ? ", showing newest \(limit)" : "")]
        for (url, values) in results.prefix(limit) {
            lines.append(describe(url, values, fullPath: true))
        }
        return lines.joined(separator: "\n")
    }

    private static func readFile(_ args: [String: Any]) throws -> String {
        let url = try resolve(args["path"])
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolError(message: "\(display(url)) does not exist")
        }
        guard !isDirectory.boolValue else { throw ToolError(message: "\(display(url)) is a directory; use list_directory") }

        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw ToolError(message: "Cannot open PDF \(display(url))") }
            let text = pdf.string ?? ""
            guard !text.isEmpty else { return "PDF \(display(url)) (\(pdf.pageCount) pages) has no extractable text." }
            return "PDF \(display(url)), \(pdf.pageCount) pages:\n\n" + text
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ToolError(message: "Cannot read \(display(url)): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxResultLength * 4)
        // 含 NUL 字节的按二进制文件处理
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw ToolError(message: "\(display(url)) is not a text file")
        }
        return text
    }

    // MARK: - 辅助

    /// ~ 开头展开为用户目录；相对路径按用户目录解析
    private static func resolve(_ value: Any?) throws -> URL {
        guard var path = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw ToolError(message: "path is required")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst(1)
        } else if !path.hasPrefix("/") {
            path = home + "/" + path
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// 用户目录显示为 ~
    private static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func describe(_ url: URL, _ values: URLResourceValues?, fullPath: Bool = false) -> String {
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        let name = fullPath ? display(url) : url.lastPathComponent
        var parts = [isFolder ? "[dir] \(name)/" : name]
        if !isFolder, let size = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let date = values?.contentModificationDate { parts.append(dateFormatter.string(from: date)) }
        return parts.joined(separator: "  ·  ")
    }

    private static func escapeQuery(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
    }
}
