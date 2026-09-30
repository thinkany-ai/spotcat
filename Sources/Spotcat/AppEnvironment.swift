import Foundation

/// 开发版与正式版隔离（参考 Douchat）：本地 make build/run 打出的是开发版，
/// scripts/release.sh 打出的是正式版。两者 Bundle ID、名称、数据目录、默认快捷键都不同，
/// 本地调试、清数据不会影响已安装的正式版，两个版本也能同时运行。
enum AppEnvironment {
    /// Info.plist 的 SpotcatChannel；scripts/bundle.sh 写入。没有 .app 包（如 swift run）时视为开发版
    static let isDevelopment: Bool = {
        (Bundle.main.object(forInfoDictionaryKey: "SpotcatChannel") as? String) != "release"
    }()

    /// make dev 通过环境变量 SPOTCAT_SOURCE_ROOT 传入仓库路径：内置聊天面板和扩展直接从源码目录加载，
    /// 改动后自动刷新（DevReload），不用重新打包
    static let sourceRoot: URL? = {
        guard isDevelopment, let path = ProcessInfo.processInfo.environment["SPOTCAT_SOURCE_ROOT"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    /// make dev 通过环境变量 SPOTCAT_EXTENSIONS_DIR 传入 spotcat-extensions 仓库的 extensions 目录：
    /// 开发中的扩展直接从源码加载并热更新，优先于插件目录里的同 id 扩展
    static let devExtensionsDirectory: URL? = {
        guard isDevelopment, let path = ProcessInfo.processInfo.environment["SPOTCAT_EXTENSIONS_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static var appName: String { isDevelopment ? "Spotcat Dev" : "Spotcat" }

    /// ~/Library/Application Support/Spotcat（正式版）或 Spotcat Dev（开发版）
    static let dataDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }()
}

/// 对外链接
enum AppLinks {
    static let website = URL(string: "https://spotcat.ai")!
    static let repository = URL(string: "https://github.com/thinkany-ai/spotcat")!
    static let issues = URL(string: "https://github.com/thinkany-ai/spotcat/issues/new")!
    static let releases = URL(string: "https://github.com/thinkany-ai/spotcat/releases")!
    /// 更新清单（scripts/publish-cdn.sh 发布到 Cloudflare R2）
    static let updateFeed = URL(string: "https://cdn.spotcat.ai/latest.json")!
    /// 插件市场目录（spotcat-extensions 仓库的 scripts/publish.sh 发布）
    /// 开发版可以用环境变量 SPOTCAT_EXTENSION_INDEX 指向测试用的目录（如本地 http.server）
    static let extensionIndex: URL = {
        if AppEnvironment.isDevelopment, let value = ProcessInfo.processInfo.environment["SPOTCAT_EXTENSION_INDEX"],
           let url = URL(string: value) {
            return url
        }
        return URL(string: "https://cdn.spotcat.ai/extensions/index.json")!
    }()
    static let extensionsRepository = URL(string: "https://github.com/thinkany-ai/spotcat-extensions")!
    /// 开发文档，中文界面打开中文版
    static var extensionsDocs: URL {
        let file = L10n.language == "zh-Hans" ? "development.zh-CN.md" : "development.md"
        return URL(string: "https://github.com/thinkany-ai/spotcat-extensions/blob/main/docs/\(file)")!
    }
    /// 提交插件收录申请
    static let submitExtension = URL(string: "https://github.com/thinkany-ai/spotcat-extensions/issues/new?template=submit-extension.yml")!
}
