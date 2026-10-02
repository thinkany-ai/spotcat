import AppKit

/// 随 App 内置、由原生代码实现的扩展。和网页扩展一样在设置里统一启用/停用，
/// 区别是不需要进入页面：条目直接参与搜索，还可以随输入实时给出结果（如计算器）。
/// 随 App 打包的网页扩展（如剪贴板历史）见 ExtensionManager 的 .builtin 来源
protocol BuiltinExtension: AnyObject {
    /// 和网页扩展共用启用状态（SettingsStore.disabledExtensions），以 "builtin." 开头避免和商店扩展重名
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var icon: (symbol: String, color: NSColor) { get }
    /// false 时设置里没有开关（Spotcat 自身的指令）
    var canDisable: Bool { get }

    /// 参与关键词模糊搜索的条目。query 已小写、去空白（可能为空）
    func items(query: String) -> [LauncherItem]
    /// 由整段输入直接生成、排在最佳结果最前的条目（如网址、「关键词 内容」的快捷链接）。text 已去掉首尾空白
    func pinnedItems(for text: String) -> [LauncherItem]
    /// 出现在「匹配推荐」里的条目（如用 AI 回答、用搜索引擎搜索）
    func suggestions(for text: String) -> [LauncherItem]
    /// 随输入实时给出的结果，显示为最前面的整行卡片。每次按键都会调用，必须足够快且没有副作用
    func answers(for text: String) -> [BuiltinAnswer]
    /// 从「最近使用」记录的 id 还原条目
    func item(forID id: String) -> LauncherItem?
}

extension BuiltinExtension {
    var canDisable: Bool { true }
    func items(query: String) -> [LauncherItem] { [] }
    func pinnedItems(for text: String) -> [LauncherItem] { [] }
    func suggestions(for text: String) -> [LauncherItem] { [] }
    func answers(for text: String) -> [BuiltinAnswer] { [] }
    func item(forID id: String) -> LauncherItem? { nil }
}

/// 内置扩展给出的即时结果，在搜索结果里显示为一张整行的卡片
struct BuiltinAnswer {
    let extensionID: String
    /// 主要内容，如计算结果
    let title: String
    /// 次要内容，如算式
    let subtitle: String
    /// 回车时复制的文本
    let copyText: String

    /// 同一扩展的结果共用一个 id，输入变化时保持选中
    var id: String { "\(extensionID):answer" }
}

enum BuiltinExtensions {
    /// 顺序即搜索结果里同类条目的顺序（如匹配推荐里 AI 对话在网页搜索之前）
    static let all: [BuiltinExtension] = [
        Calculator(), ChatExtension(), FilesExtension(), QuicklinksExtension(), SpotcatCommandsExtension(),
    ]

    static var enabled: [BuiltinExtension] {
        all.filter { !$0.canDisable || SettingsStore.shared.isExtensionEnabled($0.id) }
    }

    static func get(_ id: String) -> BuiltinExtension? {
        all.first { $0.id == id }
    }
}
