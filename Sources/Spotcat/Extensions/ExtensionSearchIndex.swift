import Foundation

/// 扩展通过 spotcat.search.setItems 交给 Spotcat 的可搜索内容（如笔记）。
/// 扩展页面不需要常驻：内容由宿主保存和匹配，命中后以 type 为 "item"、payload 为条目 id 进入对应功能。
/// 每个扩展一个文件：~/Library/Application Support/Spotcat/ExtensionData/<id>.search.json
final class ExtensionSearchIndex {
    static let shared = ExtensionSearchIndex()

    struct Item: Codable {
        let id: String
        /// 进入哪个功能
        let code: String
        let title: String
        let subtitle: String?
        /// 参与匹配但不显示的内容，如笔记正文
        let text: String?
    }

    struct Ref {
        let item: Item
        let feature: ExtensionFeatureRef
        var id: String { "idx:\(feature.extensionID)/\(item.id)" }
    }

    struct Group {
        let extensionName: String
        let items: [Ref]
    }

    static let maxItems = 2000
    private static let perExtensionResults = 5

    /// 预先小写好的匹配用文本
    private struct Entry {
        let item: Item
        let title: String
        let body: String
    }

    private var entries: [String: [Entry]] = [:]

    private static var directory: URL {
        AppEnvironment.dataDirectory.appendingPathComponent("ExtensionData", isDirectory: true)
    }

    private init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasSuffix(".search.json") {
            let id = String(file.lastPathComponent.dropLast(".search.json".count))
            if let data = try? Data(contentsOf: file), let items = try? JSONDecoder().decode([Item].self, from: data) {
                entries[id] = items.map(Self.entry)
            }
        }
    }

    private static func entry(_ item: Item) -> Entry {
        Entry(item: item, title: item.title.lowercased(), body: [item.subtitle, item.text].compactMap { $0 }.joined(separator: "\n").lowercased())
    }

    /// 整体替换某个扩展的内容；items 为空时删除
    func setItems(_ items: [Item], extensionID: String) throws {
        let url = Self.directory.appendingPathComponent("\(extensionID).search.json")
        if items.isEmpty {
            entries[extensionID] = nil
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
        entries[extensionID] = items.map(Self.entry)
    }

    /// 标题命中优先于正文，标题前缀命中再优先；每个扩展最多给几条
    func search(_ text: String, in features: [ExtensionFeatureRef]) -> [Group] {
        let query = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // 一个英文字母太宽泛；一个汉字可以
        guard query.count >= 2 || query.contains(where: { !$0.isASCII }) else { return [] }
        let enabled = Dictionary(features.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let manager = ExtensionManager.shared

        return manager.extensions.compactMap { ext -> Group? in
            guard let list = entries[ext.id] else { return nil }
            var scored: [(Ref, Int)] = []
            for (index, entry) in list.enumerated() {
                let score: Int
                if entry.title.hasPrefix(query) { score = 3 }
                else if entry.title.contains(query) { score = 2 }
                else if entry.body.contains(query) { score = 1 }
                else { continue }
                guard let feature = enabled["ext:\(ext.id)/\(entry.item.code)"] else { continue }
                // 同分时保持扩展给出的顺序（如最近修改的在前）
                scored.append((Ref(item: entry.item, feature: feature), score * 100_000 - index))
            }
            guard !scored.isEmpty else { return nil }
            let refs = scored.sorted { $0.1 > $1.1 }.prefix(Self.perExtensionResults).map(\.0)
            return Group(extensionName: ext.manifest.name, items: Array(refs))
        }
    }
}
