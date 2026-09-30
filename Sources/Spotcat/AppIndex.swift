import AppKit

struct AppItem {
    let name: String
    let url: URL
    /// 参与匹配的字符串：当前语言的名称、英文名、文件名、中文名的拼音
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
        // 应用名跟随 Spotcat 的界面语言（设置里可单独指定），其次是系统语言
        let languages = [LocaleResolver.preferred] + Locale.preferredLanguages
        DispatchQueue.global(qos: .userInitiated).async {
            let items = AppIndex.scan(languages: languages)
            DispatchQueue.main.async {
                self.items = items
                self.lastScan = Date()
                self.isScanning = false
                self.onUpdate?()
            }
        }
    }

    /// 语言切换后立即重新扫描
    func invalidate() {
        lastScan = .distantPast
        refreshIfNeeded()
    }

    private static func scan(languages: [String]) -> [AppItem] {
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

            // Spotcat 进程只有英文本地化，displayName 总是返回英文名，所以按语言直接读应用包里的名称
            let englishName = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let name = localizedName(of: url, languages: languages) ?? englishName
            let fileName = url.deletingPathExtension().lastPathComponent

            var keys = [name]
            for key in [englishName, fileName] where !keys.contains(key) { keys.append(key) }
            if let pinyin = SearchText.pinyin(of: name) { keys.append(pinyin) }

            return AppItem(name: name, url: url, searchKeys: keys)
        }
    }

    /// 应用包里指定语言的 CFBundleDisplayName 或 CFBundleName；没有本地化时返回 nil。
    /// 名称在 <语言>.lproj/InfoPlist.strings 或 InfoPlist.loctable（系统应用，{语言: {key: 值}}）里
    private static func localizedName(of url: URL, languages: [String]) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        let loctable = bundle.url(forResource: "InfoPlist", withExtension: "loctable")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: [String: Any]] }
        let available = Array(Set(bundle.localizations + (loctable.map { Array($0.keys) } ?? [])))
        let localization = Bundle.preferredLocalizations(from: available, forPreferences: languages).first
        // 首选语言与应用的开发语言相同时（如英文界面），名称就是 Info.plist 里的，不用再找
        guard let localization, localization != "Base" else { return nil }

        var table = loctable?[localization]
        if table == nil, let path = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: localization) {
            table = NSDictionary(contentsOfFile: path) as? [String: Any]
        }
        guard let table else { return nil }
        return ["CFBundleDisplayName", "CFBundleName"].compactMap { table[$0] as? String }.first { !$0.isEmpty }
    }
}

/// 记录启动次数和时间，用于排序加权和「最近使用」。
/// key 是 LauncherItem.id：应用为路径，扩展功能为 "ext:<扩展id>/<功能code>"
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
        return Array(dates.sorted { $0.value > $1.value }.map(\.key).prefix(limit))
    }
}
