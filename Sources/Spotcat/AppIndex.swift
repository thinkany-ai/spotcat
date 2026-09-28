import AppKit

struct AppItem {
    let name: String
    let url: URL
    /// 参与匹配的字符串：显示名、英文文件名、中文名的拼音
    let searchKeys: [String]
}

/// 扫描常见目录下的 .app，在后台线程完成。
final class AppIndex {
    private(set) var items: [AppItem] = []
    var onUpdate: (() -> Void)?

    private var lastScan = Date.distantPast
    private var isScanning = false

    func refreshIfNeeded(maxAge: TimeInterval = 10) {
        guard !isScanning, Date().timeIntervalSince(lastScan) > maxAge else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let items = AppIndex.scan()
            DispatchQueue.main.async {
                self.items = items
                self.lastScan = Date()
                self.isScanning = false
                self.onUpdate?()
            }
        }
    }

    private static func scan() -> [AppItem] {
        let fm = FileManager.default
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
            NSString(string: "~/Applications").expandingTildeInPath,
        ].map { URL(fileURLWithPath: $0) }

        var seen = Set<String>()
        var urls: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                if url.pathExtension == "app" {
                    urls.append(url)
                    enumerator.skipDescendants()
                } else if enumerator.level >= 3 {
                    enumerator.skipDescendants()
                }
            }
        }

        return urls.compactMap { url in
            let path = url.resolvingSymlinksInPath().path
            guard fm.fileExists(atPath: path), seen.insert(path).inserted else { return nil }

            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let fileName = url.deletingPathExtension().lastPathComponent

            var keys = [name]
            if fileName != name { keys.append(fileName) }
            if let pinyin = SearchText.pinyin(of: name) { keys.append(pinyin) }

            return AppItem(name: name, url: url, searchKeys: keys)
        }
    }
}

/// 记录启动次数和时间，用于排序加权和「最近使用」。
/// key 是 LauncherItem.id：应用为路径（兼容旧数据），扩展功能为 "ext:<扩展id>/<功能code>"
enum UsageStore {
    private static let key = "launchCounts"
    private static let lastLaunchKey = "lastLaunchDates"

    static func count(for id: String) -> Int {
        (UserDefaults.standard.dictionary(forKey: key)?[id] as? Int) ?? 0
    }

    static func recordLaunch(id: String) {
        var counts = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        counts[id] = ((counts[id] as? Int) ?? 0) + 1
        UserDefaults.standard.set(counts, forKey: key)

        var dates = UserDefaults.standard.dictionary(forKey: lastLaunchKey) ?? [:]
        dates[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dates, forKey: lastLaunchKey)
    }

    /// 清除启动次数和时间：「最近使用」清空，排序不再受历史影响
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: lastLaunchKey)
    }

    /// 最近使用过的条目 id，新的在前
    static func recentIDs(limit: Int) -> [String] {
        let dates = UserDefaults.standard.dictionary(forKey: lastLaunchKey) as? [String: Double] ?? [:]
        let counts = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        // 旧版本只记了次数，没有时间的按次数排在后面
        let dated = dates.sorted { $0.value > $1.value }.map(\.key)
        let undated = counts.filter { dates[$0.key] == nil }.sorted { $0.value > $1.value }.map(\.key)
        return Array((dated + undated).prefix(limit))
    }
}
