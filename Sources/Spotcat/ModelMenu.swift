import AppKit
import SwiftUI

/// 所有选择模型的地方共用的原生菜单：按服务商分组，每项上面是模型名称，下面是「服务商 id/模型 id」。
/// 设置里的默认模型、聊天的切换模型、扩展的 spotcat.ai.pickModel 都用它
enum ModelMenu {
    struct Options {
        /// 当前选中的引用，打勾
        var current: String?
        /// 未填 Key 的服务商下的模型不可选（聊天、扩展里选了也用不了；设置默认模型时可以先选）
        var requireKey = true
        /// 第一项「跟随默认模型」，选中时返回空字符串（扩展用）
        var includeDefault = false
        /// 末尾「管理模型…」
        var includeManage = false
    }

    enum Result {
        case model(String)
        /// 跟随默认模型
        case followDefault
        case manage
    }

    /// 生成菜单项；action 统一走 target.pick(_:)，结果存在 target.result
    static func menu(config: ModelsConfig, options: Options, target: Target) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = options.current.map(config.canonical)

        if options.includeDefault {
            let fallback = config.resolvedDefault.map { "\($0.provider.name) · \($0.model.displayTitle)" } ?? "—"
            let item = entry(title: L10n.t("models.menu.followDefault"), subtitle: fallback, target: target)
            item.representedObject = Target.followDefaultMarker
            item.state = (current ?? "").isEmpty ? .on : .off
            menu.addItem(item)
            menu.addItem(.separator())
        }

        for provider in config.providers where !provider.models.isEmpty {
            let usable = provider.hasKey || !options.requireKey
            let name = provider.hasKey ? provider.name : "\(provider.name) — \(L10n.t("chat.model.noKey"))"
            menu.addItem(header(name))
            for model in provider.models {
                let reference = ModelsConfig.reference(provider, model)
                let item = entry(title: model.displayTitle, subtitle: reference, target: target)
                item.representedObject = reference
                item.state = reference == current ? .on : .off
                item.isEnabled = usable
                menu.addItem(item)
            }
        }

        if options.includeManage {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let manage = NSMenuItem(title: L10n.t("chat.model.manage"), action: #selector(Target.manage(_:)), keyEquivalent: "")
            manage.target = target
            menu.addItem(manage)
        }
        return menu
    }

    /// 两行：模型名称 + 灰色小字的引用（macOS 14.4 起用系统的 subtitle）
    private static func entry(title: String, subtitle: String, target: Target) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Target.pick(_:)), keyEquivalent: "")
        item.target = target
        if #available(macOS 14.4, *) {
            item.subtitle = subtitle
        } else {
            let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = text
        }
        return item
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 在 view 里给定的位置（view 坐标，左上角为原点）弹出菜单，菜单关闭后返回结果
    static func popUp(in view: NSView, at topLeft: NSPoint, above: Bool, options: Options) -> Result? {
        let target = Target()
        let menu = menu(config: SettingsStore.shared.models, options: options, target: target)
        let point = NSPoint(x: topLeft.x, y: view.isFlipped ? topLeft.y : view.bounds.height - topLeft.y)
        menu.popUp(positioning: above ? menu.items.last : nil, at: point, in: view)
        return target.result
    }

    /// NSMenu 的 action 需要一个 NSObject target；popUp 返回前 action 已经执行，结果存在这里
    final class Target: NSObject {
        static let followDefaultMarker = "\u{0}default"
        var result: Result?
        var onPick: ((Result) -> Void)?

        @objc func pick(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            result = id == Self.followDefaultMarker ? .followDefault : .model(id)
            onPick?(result!)
        }

        @objc func manage(_ sender: NSMenuItem) {
            result = .manage
            onPick?(.manage)
        }
    }
}

/// 设置页里的模型选择按钮：显示当前模型名称，点开是 ModelMenu
struct ModelPopUpButton: NSViewRepresentable {
    @Binding var selection: String
    let config: ModelsConfig

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let target = context.coordinator.target
        target.onPick = { result in
            if case .model(let id) = result { selection = id }
        }
        let current = config.resolvedDefault.map { ModelsConfig.reference($0.provider, $0.model) }
        button.menu = ModelMenu.menu(config: config, options: .init(current: selection, requireKey: false), target: target)
        let index = button.menu?.items.firstIndex { ($0.representedObject as? String) == config.canonical(selection) }
            ?? button.menu?.items.firstIndex { ($0.representedObject as? String) == current }
        if let index { button.selectItem(at: index) }
    }

    final class Coordinator {
        let target = ModelMenu.Target()
    }
}
