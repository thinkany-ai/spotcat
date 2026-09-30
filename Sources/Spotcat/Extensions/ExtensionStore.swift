import AppKit
import CryptoKit

/// 插件市场：读取 CDN 上的插件目录（https://cdn.spotcat.ai/extensions/index.json，
/// 由 spotcat-extensions 仓库的 scripts/publish.sh 发布），按需下载、更新、卸载插件。
///
/// 安装：下载 zip → 校验 SHA256 → 解压到临时目录 → 检查 manifest 的 id / 版本与目录一致 →
/// 替换 ~/Library/Application Support/Spotcat/Extensions/<id>，并写入安装记录（InstallRecord）。
/// 没有安装记录的目录视为用户自己放进去的本地插件，市场不会覆盖或更新它。
final class ExtensionStore: ObservableObject {
    static let shared = ExtensionStore()

    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    enum TaskState: Equatable {
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var entries: [StoreEntry] = []
    @Published private(set) var loadState: LoadState = .idle
    /// 正在安装 / 更新的插件（按 id）
    @Published private(set) var tasks: [String: TaskState] = [:]

    private var recommended: [String] = []
    private var lastLoad = Date.distantPast
    private static let bootstrappedKey = "extensionsBootstrapped"

    private let manager = ExtensionManager.shared

    // MARK: - 目录

    /// maxAge 内已加载过就不重复请求
    func refresh(maxAge: TimeInterval = 0, completion: (() -> Void)? = nil) {
        guard loadState != .loading else { return }
        if loadState == .loaded, Date().timeIntervalSince(lastLoad) < maxAge {
            completion?()
            return
        }
        loadState = .loading

        var request = URLRequest(url: AppLinks.extensionIndex, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<StoreIndex, Error> = Result {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                    throw StoreError.message(L10n.t("store.error.index"))
                }
                return try JSONDecoder().decode(StoreIndex.self, from: data)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let index):
                    self.entries = index.extensions
                    self.recommended = index.recommended ?? []
                    self.loadState = .loaded
                    self.lastLoad = Date()
                case .failure(let error):
                    self.loadState = .failed(error.localizedDescription)
                }
                completion?()
            }
        }.resume()
    }

    func entry(id: String) -> StoreEntry? {
        entries.first { $0.id == id }
    }

    /// 已从市场安装、且市场上有更高版本的插件
    var updates: [StoreEntry] {
        entries.filter { entry in
            guard let installed = manager.extensions.first(where: { $0.id == entry.id }),
                  installed.source.isStore else { return false }
            return Version(entry.version) > Version(installed.manifest.version) && entry.isCompatible
        }
    }

    func hasUpdate(_ ext: SpotcatExtension) -> Bool {
        updates.contains { $0.id == ext.id }
    }

    /// 首次运行新版本时装上推荐插件（翻译、编码等以前内置的插件），成功一次后不再自动安装，
    /// 用户卸载了也不会被装回来
    func bootstrapIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.bootstrappedKey) else { return }
        refresh { [weak self] in
            guard let self, self.loadState == .loaded else { return }
            UserDefaults.standard.set(true, forKey: Self.bootstrappedKey)
            let installed = Set(self.manager.extensions.map(\.id))
            for id in self.recommended where !installed.contains(id) {
                if let entry = self.entry(id: id), entry.isCompatible { self.install(entry) }
            }
        }
    }

    // MARK: - 安装 / 卸载

    func install(_ entry: StoreEntry) {
        guard tasks[entry.id] == nil || tasks[entry.id]?.isFailure == true else { return }
        guard entry.isCompatible else {
            tasks[entry.id] = .failed(L10n.t("store.error.appTooOld", entry.minAppVersion ?? ""))
            return
        }
        tasks[entry.id] = .downloading(0)

        let task = URLSession.shared.downloadTask(with: entry.url) { [weak self] location, response, error in
            let result: Result<Void, Error> = Result {
                if let error { throw error }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw StoreError.message(L10n.t("store.error.download"))
                }
                try Self.installPackage(at: location, entry: entry)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressObservers[entry.id] = nil
                switch result {
                case .success:
                    self.tasks[entry.id] = nil
                    self.extensionsDidChange()
                case .failure(let error):
                    NSLog("%@", "Spotcat: 安装插件 \(entry.id) 失败：\(error)")
                    self.tasks[entry.id] = .failed(error.localizedDescription)
                }
            }
        }
        progressObservers[entry.id] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                guard case .downloading = self?.tasks[entry.id] else { return }
                self?.tasks[entry.id] = .downloading(progress.fractionCompleted)
            }
        }
        task.resume()
    }

    private var progressObservers: [String: NSKeyValueObservation] = [:]

    func updateAll() {
        updates.forEach(install)
    }

    /// 移到废纸篓（本地插件也可以，方便用户找回）
    func uninstall(_ ext: SpotcatExtension) {
        NSWorkspace.shared.recycle([ext.directory]) { [weak self] _, error in
            if let error { NSLog("%@", "Spotcat: 卸载插件 \(ext.id) 失败：\(error)") }
            self?.extensionsDidChange()
        }
    }

    private func extensionsDidChange() {
        manager.reload()
        SettingsStore.shared.onExtensionsChange?()
        objectWillChange.send()
    }

    /// 在后台线程执行：校验、解压、替换目录
    private static func installPackage(at zip: URL, entry: StoreEntry) throws {
        let fm = FileManager.default
        let data = try Data(contentsOf: zip)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256.lowercased() else {
            throw StoreError.message(L10n.t("store.error.checksum"))
        }

        let staging = fm.temporaryDirectory.appendingPathComponent("spotcat-ext-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw StoreError.message(L10n.t("store.error.unzip")) }

        // 包里的 manifest 必须和目录条目一致，防止被换成别的插件
        let manifestData = try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: manifestData)
        guard manifest.id == entry.id, manifest.version == entry.version else {
            throw StoreError.message(L10n.t("store.error.mismatch"))
        }
        let record = InstallRecord(source: "store", version: entry.version, official: entry.official ?? false, installedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: staging.appendingPathComponent(InstallRecord.fileName))

        let root = ExtensionManager.userExtensionsDirectory
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(entry.id, isDirectory: true)
        // 同名的本地插件（没有安装记录，可能是用户正在开发的）不覆盖
        if fm.fileExists(atPath: target.path), InstallRecord.load(from: target) == nil {
            throw StoreError.message(L10n.t("store.error.localExists"))
        }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
    }
}

enum StoreError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

extension ExtensionStore.TaskState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - 数据

/// 插件目录中的一段文案：字符串，或 { 语言: 文案 }
struct LocalizedText: Decodable, Equatable {
    let values: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            values = ["": text]
        } else {
            values = try container.decode([String: String].self)
        }
    }

    var text: String {
        if let plain = values[""] { return plain }
        let locale = LocaleResolver.best(among: Array(values.keys), defaultLocale: "en")
        return values[locale] ?? values.values.first ?? ""
    }
}

struct StoreIndex: Decodable {
    let recommended: [String]?
    let extensions: [StoreEntry]
}

struct StoreEntry: Decodable, Identifiable, Equatable {
    struct Feature: Decodable, Equatable {
        let code: String
        let title: LocalizedText
    }

    let id: String
    let version: String
    let name: LocalizedText
    let description: LocalizedText?
    let author: String?
    /// "sf:<SF Symbol>" 或图片 URL
    let icon: String?
    let iconColor: String?
    let permissions: [String]?
    let features: [Feature]?
    let homepage: URL?
    let minAppVersion: String?
    let official: Bool?
    let url: URL
    let sha256: String
    let size: Int?

    var isCompatible: Bool {
        guard let minAppVersion else { return true }
        return Version(Updater.shared.currentVersion) >= Version(minAppVersion)
    }
}

/// 从市场安装的插件目录里的 .spotcat-install.json
struct InstallRecord: Codable {
    static let fileName = ".spotcat-install.json"

    let source: String
    let version: String
    let official: Bool
    let installedAt: Date

    static func load(from directory: URL) -> InstallRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallRecord.self, from: data)
    }
}

/// x.y.z 比较；预发布后缀（-beta.1）低于正式版
struct Version: Comparable {
    private let numbers: [Int]
    private let prerelease: String?

    init(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 1)
        numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        for i in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let a = i < lhs.numbers.count ? lhs.numbers[i] : 0
            let b = i < rhs.numbers.count ? rhs.numbers[i] : 0
            if a != b { return a < b }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case let (a?, b?): return a.compare(b, options: .numeric) == .orderedAscending
        }
    }

    static func == (lhs: Version, rhs: Version) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
