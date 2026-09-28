import AppKit

/// 快捷链接：关键词 + 网址模板，模板中的 {query} 会替换为关键词后面输入的内容
struct Quicklink: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var keyword: String
    var url: String

    static let placeholder = "{query}"

    var acceptsQuery: Bool { url.contains(Self.placeholder) }

    /// 有查询词时填入模板；没有时打开网站首页
    func resolvedURL(query: String?) -> URL? {
        if let query, !query.isEmpty, acceptsQuery {
            // 查询参数里 & + = ? # 等也要转义
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=?#/")
            let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
            return URL(string: url.replacingOccurrences(of: Self.placeholder, with: encoded))
        }
        let base = url.replacingOccurrences(of: Self.placeholder, with: "")
        guard let components = URLComponents(string: base), let scheme = components.scheme, let host = components.host else {
            return URL(string: base)
        }
        return URL(string: "\(scheme)://\(host)")
    }

    var host: String? {
        URLComponents(string: url.replacingOccurrences(of: Self.placeholder, with: ""))?.host
    }

    static let defaults: [Quicklink] = [
        Quicklink(id: "google", name: "Google", keyword: "g", url: "https://www.google.com/search?q={query}"),
        Quicklink(id: "baidu", name: "百度", keyword: "bd", url: "https://www.baidu.com/s?wd={query}"),
        Quicklink(id: "bing", name: "Bing", keyword: "bing", url: "https://www.bing.com/search?q={query}"),
        Quicklink(id: "github", name: "GitHub", keyword: "gh", url: "https://github.com/search?q={query}"),
        Quicklink(id: "youtube", name: "YouTube", keyword: "yt", url: "https://www.youtube.com/results?search_query={query}"),
        Quicklink(id: "bilibili", name: "哔哩哔哩", keyword: "bili", url: "https://search.bilibili.com/all?keyword={query}"),
        Quicklink(id: "wikipedia", name: "Wikipedia", keyword: "wiki", url: "https://www.wikipedia.org/search-redirect.php?search={query}"),
    ]
}

/// 判断输入是否像网址。刻意保守：带 scheme、www.、常见顶级域名、localhost 或 IP，
/// 避免把 readme.md、Package.swift 这类文件名当成网址
enum WebAddress {
    private static let commonTLDs: Set<String> = [
        "com", "cn", "net", "org", "io", "dev", "ai", "app", "co", "me", "xyz", "top", "gov", "edu",
        "info", "tv", "cc", "so", "sh", "gg", "jp", "uk", "de", "fr", "us", "hk", "tw", "site", "tech", "fun", "vip",
    ]

    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: text).flatMap { $0.host == nil ? nil : $0 }
        }

        let hostPart = String(lower.split(separator: "/", maxSplits: 1).first ?? "")
        let host = String(hostPart.split(separator: ":").first ?? "")
        let isLocal = host == "localhost" || host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
        let tld = host.split(separator: ".").last.map(String.init) ?? ""
        let isDomain = host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
            && host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
            && (host.hasPrefix("www.") || commonTLDs.contains(tld))

        guard isLocal || isDomain else { return nil }
        return URL(string: (isLocal ? "http://" : "https://") + text)
    }

    /// 显示用：去掉 scheme 和末尾的 /
    static func display(_ url: URL) -> String {
        var text = url.absoluteString.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// 网站图标：从 https://<host>/favicon.ico 下载，缓存在 ~/Library/Application Support/Spotcat/Favicons
final class FaviconCache: ObservableObject {
    static let shared = FaviconCache()

    /// 每下载完成一个图标加一，让 SwiftUI 视图刷新
    @Published private(set) var revision = 0

    /// 有新图标下载完成时回调（用于刷新结果）
    var onUpdate: (() -> Void)?

    private var memory: [String: NSImage] = [:]
    private var failed = Set<String>()
    private var loading = Set<String>()

    private var directory: URL {
        SettingsStore.dataDirectory.appendingPathComponent("Favicons", isDirectory: true)
    }

    /// 已缓存时返回图标，否则触发下载并返回 nil
    func icon(for host: String) -> NSImage? {
        if let image = memory[host] { return image }
        let file = directory.appendingPathComponent(host)
        if let image = NSImage(contentsOf: file) {
            memory[host] = image
            return image
        }
        fetch(host)
        return nil
    }

    private func fetch(_ host: String) {
        guard !failed.contains(host), !loading.contains(host),
              let url = URL(string: "https://\(host)/favicon.ico") else { return }
        loading.insert(host)
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 8)) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(host)
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                guard ok, let data, let image = NSImage(data: data), image.isValid else {
                    self.failed.insert(host)
                    return
                }
                try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try? data.write(to: self.directory.appendingPathComponent(host))
                self.memory[host] = image
                self.revision += 1
                self.onUpdate?()
            }
        }.resume()
    }
}
