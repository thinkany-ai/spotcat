import Foundation

/// 开发版与正式版隔离（参考 Douchat）：本地 make build/run 打出的是开发版，
/// scripts/release.sh 打出的是正式版。两者 Bundle ID、名称、数据目录、默认快捷键都不同，
/// 本地调试、清数据不会影响已安装的正式版，两个版本也能同时运行。
enum AppEnvironment {
    /// Info.plist 的 SpotcatChannel；scripts/bundle.sh 写入。没有 .app 包（如 swift run）时视为开发版
    static let isDevelopment: Bool = {
        (Bundle.main.object(forInfoDictionaryKey: "SpotcatChannel") as? String) != "release"
    }()

    static var appName: String { isDevelopment ? "Spotcat Dev" : "Spotcat" }

    /// ~/Library/Application Support/Spotcat（正式版）或 Spotcat Dev（开发版）
    static let dataDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }()
}
