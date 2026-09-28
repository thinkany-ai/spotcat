import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, extensions, quicklinks, profile, ai, about

    var id: String { rawValue }
    var title: String { L10n.t("settings.tab.\(rawValue)") }
    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        case .quicklinks: return "link"
        case .profile: return "person.crop.circle.fill"
        case .ai: return "cpu"
        case .about: return "info.circle.fill"
        }
    }

    /// 侧边栏图标底色（系统设置风格的彩色圆角方块）
    var tint: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .extensions: return Color(nsColor: .systemIndigo)
        case .quicklinks: return Color(nsColor: .systemBlue)
        case .profile: return Color(nsColor: .systemOrange)
        case .ai: return Color(nsColor: .systemTeal)
        case .about: return Color(nsColor: .systemGray)
        }
    }

    /// 个人资料在侧边栏顶部以卡片形式出现，不在列表里
    static let sidebarItems: [SettingsTab] = [.general, .extensions, .quicklinks, .ai, .about]
}

/// 当前选中的标签页（Command Line Tools 没有 SwiftUI 宏，不能用 @State）
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsTab? = .general
    /// 快捷链接页正在编辑的条目
    @Published var editingQuicklink: String?
    /// 模型页正在编辑的服务商，以及它的测试结果
    @Published var editingProvider: String?
    /// 编辑中的模型列表原文（一行一个），完成或测试时才解析
    @Published var modelsDraft = ""
    @Published var providerTest: ProviderTest?
    /// 模型页的提示（如导入结果）
    @Published var modelsNotice: String?

    enum ProviderTest: Equatable {
        case running
        case passed(String)
        case failed(String)
    }
}

final class SettingsWindowController {
    private let store: SettingsStore
    private let recorder: ShortcutRecorderModel
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
        recorder = ShortcutRecorderModel(store: store)
    }

    func show(tab: SettingsTab? = nil) {
        store.refreshLaunchAtLogin()
        if let tab { navigation.selection = tab }

        if window == nil {
            let root = SettingsRootView(store: store, navigation: navigation, recorder: recorder)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = L10n.t("settings.title")
            // 内容延伸到标题栏下，侧边栏一直到顶部（系统设置风格）
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        // accessory App 需要主动激活，窗口才能拿到焦点
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func localeDidChange() {
        window?.title = L10n.t("settings.title")
    }
}

/// 左侧标签栏 + 右侧内容
struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var navigation: SettingsNavigation
    let recorder: ShortcutRecorderModel

    private var selection: SettingsTab { navigation.selection ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(VisualEffectBackground(material: .sidebar))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                // 与红绿灯同一高度的页面标题
                Text(selection.title)
                    .font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, 28)
                    .frame(height: 52)
                content(for: selection)
                    // 表单背景透明，和标题区域用同一种底色
                    .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 800, height: 580)
        .ignoresSafeArea()
        // 开关、按钮等控件使用主题色
        .tint(Theme.accent)
        // 语言切换后整棵树重建，所有文案随之刷新
        .id(store.language)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 留出红绿灯的位置
            Spacer().frame(height: 48)

            ProfileCard(store: store, isSelected: selection == .profile) {
                navigation.selection = .profile
            }
            .padding(.bottom, 10)

            ForEach(SettingsTab.sidebarItems) { tab in
                SidebarRow(tab: tab, isSelected: selection == tab) {
                    navigation.selection = tab
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(store: store, recorder: recorder)
        case .extensions: ExtensionsSettingsView(store: store, manager: .shared)
        case .quicklinks: QuicklinksSettingsView(store: store, navigation: navigation)
        case .profile: ProfileSettingsView(store: store)
        case .ai: ModelsSettingsView(store: store, navigation: navigation)
        case .about: AboutSettingsView(store: store, updater: .shared)
        }
    }
}

private struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: tab.icon, tint: tab.tint)
                Text(tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Theme.accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 侧边栏顶部的个人资料卡片，相当于「个人资料」入口
private struct ProfileCard: View {
    @ObservedObject var store: SettingsStore
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AvatarView(image: store.avatar, name: store.nickname, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.nickname.isEmpty ? L10n.t("settings.profile.cardTitle") : store.nickname)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(L10n.t("settings.profile.cardSubtitle"))
                        .font(.system(size: 11))
                        .opacity(0.7)
                        .lineLimit(1)
                }
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Theme.accent : Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 彩色圆角方块 + 白色符号
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27).fill(tint.gradient))
    }
}

/// 分组下方的说明文字，统一左对齐
struct SettingsFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
