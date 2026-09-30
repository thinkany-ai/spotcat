import CoreServices
import Foundation

/// make dev 的页面热更新：用 FSEvents 监听源码里的聊天面板和扩展目录，文件变化时发出通知，
/// 由 WebBridge 刷新对应的页面。只在设置了 AppEnvironment.sourceRoot 时启用
enum DevReload {
    static let didChange = Notification.Name("SpotcatDevReloadDidChange")
    /// userInfo 中变化的文件路径（[String]，已解析软链接）
    static let pathsKey = "paths"

    private static var stream: FSEventStreamRef?

    /// 开始监听（重复调用无副作用），返回是否处于热更新模式
    @discardableResult
    static func start() -> Bool {
        guard let root = AppEnvironment.sourceRoot else { return false }
        guard stream == nil else { return true }
        let paths = ["Resources/chat", "extensions"].map {
            root.appendingPathComponent($0).resolvingSymlinksInPath().path
        }
        let callback: FSEventStreamCallback = { _, _, count, eventPaths, _, _ in
            guard let changed = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            let files = Array(changed.prefix(count)).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            NotificationCenter.default.post(name: DevReload.didChange, object: nil, userInfo: [DevReload.pathsKey: files])
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil, callback, nil, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
        NSLog("%@", "Spotcat: 热更新已开启，监听 \(paths.joined(separator: ", "))")
        return true
    }
}
