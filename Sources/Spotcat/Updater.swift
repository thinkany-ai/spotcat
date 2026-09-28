import AppKit
import CryptoKit
import Security

/// 从 CDN 上的更新清单（https://cdn.spotcat.ai/latest.json）检查并安装新版本。
///
/// 安装前校验：ZIP 的 SHA256 与清单一致；下载的 App 必须 Bundle ID 相同、签名有效，且与当前 App 由同一开发者团队签名；
/// 然后原地替换当前 App 并重启。开发版和 ad-hoc 签名的本地构建不参与更新。
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case idle
        /// 开发版 / 本地构建
        case disabled
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let notes: String
        let downloadURL: URL
        let pageURL: URL
        /// 清单中 ZIP 的 SHA256（小写十六进制）
        let sha256: String?
    }

    @Published private(set) var status: Status = .idle

    private var timer: Timer?
    private var downloadSession: URLSession?
    private var pendingRelease: Release?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var availableRelease: Release? {
        if case .available(let release) = status { return release }
        return nil
    }

    // MARK: - 检查

    /// 启动 15 秒后检查一次，之后每 6 小时检查一次（受「自动检查更新」设置控制）
    func startAutomaticChecks() {
        guard !AppEnvironment.isDevelopment else {
            status = .disabled
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.automaticCheck()
        }
    }

    private func automaticCheck() {
        guard SettingsStore.shared.autoCheckUpdates else { return }
        switch status {
        case .downloading, .installing, .checking: return
        default: check(silent: true)
        }
    }

    /// silent 为 true 时失败不显示错误（自动检查）
    func check(silent: Bool = false) {
        guard !AppEnvironment.isDevelopment else {
            status = .disabled
            return
        }
        status = .checking

        var request = URLRequest(url: AppLinks.updateFeed, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, httpStatus == 200, let data,
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let message = error?.localizedDescription ?? L10n.t("update.error.service", httpStatus)
                    self.status = silent ? .idle : .failed(message)
                    return
                }
                if let release = self.newerRelease(in: manifest) {
                    self.status = .available(release)
                } else {
                    self.status = silent ? .idle : .upToDate
                }
            }
        }.resume()
    }

    /// 清单中的版本比当前新时返回
    private func newerRelease(in manifest: [String: Any]) -> Release? {
        guard let version = manifest["version"] as? String,
              let url = (manifest["url"] as? String).flatMap(URL.init(string:)),
              Self.compare(version, currentVersion) == .orderedDescending else { return nil }
        let page = (manifest["page"] as? String).flatMap(URL.init(string:)) ?? AppLinks.releases
        return Release(version: version, notes: manifest["notes"] as? String ?? "", downloadURL: url,
                       pageURL: page, sha256: (manifest["sha256"] as? String)?.lowercased())
    }

    /// 语义化版本比较：1.2.10 > 1.2.9，1.2.0 > 1.2.0-beta.1
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ v: String) -> ([Int], String?) {
            let parts = v.split(separator: "-", maxSplits: 1).map(String.init)
            return (parts[0].split(separator: ".").map { Int($0) ?? 0 }, parts.count > 1 ? parts[1] : nil)
        }
        let (na, pa) = split(a), (nb, pb) = split(b)
        for i in 0..<max(na.count, nb.count) {
            let x = i < na.count ? na[i] : 0, y = i < nb.count ? nb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (pa, pb) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?): return x.compare(y, options: .numeric)
        }
    }

    // MARK: - 下载与安装

    func install() {
        guard let release = availableRelease else { return }
        pendingRelease = release
        status = .downloading(0)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadSession = session
        session.downloadTask(with: release.downloadURL).resume()
    }

    fileprivate func finishDownload(at location: URL) {
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        status = .installing
        do {
            if let expected = pendingRelease?.sha256, try Self.sha256(of: location) != expected {
                throw UpdateError(L10n.t("update.error.checksum"))
            }
            let newApp = try extract(zip: location)
            try verify(newApp)
            try replaceAndRelaunch(with: newApp)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    fileprivate func failDownload(_ error: Error) {
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        status = .failed(error.localizedDescription)
    }

    private var currentBundleURL: URL { Bundle.main.bundleURL }

    private static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 解压到与当前 App 同一卷上的临时目录，便于原子替换
    private func extract(zip: URL) throws -> URL {
        let workDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: currentBundleURL, create: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, workDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let app = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError(L10n.t("update.error.archive"))
        }
        return app
    }

    /// 同一 Bundle ID + 签名有效 + 与当前 App 同一开发者团队
    private func verify(_ app: URL) throws {
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError(L10n.t("update.error.identity"))
        }
        guard let team = Self.currentTeamIdentifier() else {
            throw UpdateError(L10n.t("update.error.unsigned"))
        }
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecRequirementCreateWithString(requirementText, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
                                         requirement) == errSecSuccess else {
            throw UpdateError(L10n.t("update.error.signature"))
        }
    }

    /// 当前运行中 App 的签名团队 ID；ad-hoc 签名（本地构建）返回 nil
    private static func currentTeamIdentifier() -> String? {
        var running: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func replaceAndRelaunch(with newApp: URL) throws {
        let target = currentBundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError(L10n.t("update.error.permission"))
        }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp)

        // 等当前进程退出后重新打开新版本
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", target.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }
}

extension Updater: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        status = .downloading(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 回调返回后临时文件会被删除，先移走
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Spotcat-update-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finishDownload(at: kept)
        } catch {
            failDownload(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { failDownload(error) }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
