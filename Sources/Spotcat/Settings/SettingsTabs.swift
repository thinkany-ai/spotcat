import AppKit
import ServiceManagement
import SwiftUI

// MARK: - 通用

struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    let recorder: ShortcutRecorderModel

    var body: some View {
        Form {
            Section(L10n.t("settings.section.appearance")) {
                Picker(L10n.t("settings.appearance"), selection: $store.appearance) {
                    Text(L10n.t("settings.followSystem")).tag(SettingsStore.followSystem)
                    Text(L10n.t("settings.appearance.light")).tag("light")
                    Text(L10n.t("settings.appearance.dark")).tag("dark")
                }
                .pickerStyle(.segmented)

                Picker(L10n.t("settings.language"), selection: $store.language) {
                    Text(L10n.t("settings.followSystem")).tag(SettingsStore.followSystem)
                    Text(verbatim: "简体中文").tag("zh-Hans")
                    Text(verbatim: "English").tag("en")
                }
            }

            Section(L10n.t("settings.section.startup")) {
                Toggle(L10n.t("settings.launchAtLogin"), isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))

                if store.launchAtLoginStatus == .requiresApproval {
                    HStack {
                        Text(L10n.t("settings.requiresApproval"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.t("settings.openSystemSettings")) {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }

                if let error = store.launchAtLoginError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }

                LabeledContent(L10n.t("settings.shortcut.open")) {
                    HStack(spacing: 6) {
                        if !store.isAutomaticShortcut {
                            Button {
                                store.useAutomaticShortcut()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.t("settings.shortcut.reset", Shortcut.default.displayString))
                        }
                        ShortcutRecorder(store: store, model: recorder)
                    }
                }

                if let error = store.shortcutError {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else if store.isAutomaticShortcut, let owner = store.defaultShortcutOwner {
                    HStack {
                        Text(L10n.t("settings.shortcut.defaultTaken", Shortcut.default.displayString, owner.name, store.shortcut.displayString))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if owner != .spotcat {
                            Button(L10n.t("settings.shortcut.useDefault", Shortcut.default.displayString)) {
                                (NSApp.delegate as? AppDelegate)?.showDefaultShortcutPrompt(owner: owner, allowSuppress: false)
                            }
                        }
                    }
                }
            }

            Section {
                Toggle(L10n.t("settings.results.recents"), isOn: $store.showRecents)
                Toggle(L10n.t("settings.results.suggestions"), isOn: $store.showSuggestions)
                LabeledContent {
                    Button(L10n.t("settings.results.clear"), action: store.clearUsageHistory)
                } label: {
                    Text(L10n.t("settings.results.history"))
                    Text(L10n.t("settings.results.historyHelp"))
                }
            } header: {
                Text(L10n.t("settings.results"))
            }

            Section(L10n.t("settings.window")) {
                Toggle(isOn: $store.keepOpen) {
                    Text(L10n.t("settings.keepOpen"))
                    Text(L10n.t("settings.keepOpen.help"))
                }
                LabeledContent {
                    Button(L10n.t("settings.reset")) {
                        NSApp.sendAction(#selector(AppDelegate.resetPosition), to: nil, from: nil)
                    }
                } label: {
                    Text(L10n.t("settings.resetPosition"))
                    Text(L10n.t("settings.resetPosition.help"))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 个人资料

struct ProfileSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.t("settings.profile.avatar")) {
                    HStack(spacing: 14) {
                        AvatarView(image: store.avatar, name: store.nickname, size: 56)
                        VStack(alignment: .leading, spacing: 6) {
                            Button(L10n.t("settings.profile.chooseAvatar"), action: chooseAvatar)
                            if store.avatar != nil {
                                Button(L10n.t("settings.profile.removeAvatar"), role: .destructive, action: store.removeAvatar)
                                    .buttonStyle(.link)
                            }
                        }
                    }
                }

                TextField(L10n.t("settings.profile.nickname"), text: $store.nickname,
                          prompt: Text(L10n.t("settings.profile.nicknamePlaceholder")))
            } footer: {
                SettingsFooter(L10n.t("settings.profile.footer"))
            }
        }
        .formStyle(.grouped)
    }

    private func chooseAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setAvatar(from: url)
    }
}

/// 圆形头像；没有图片时显示昵称首字或默认图标
struct AvatarView: View {
    let image: NSImage?
    let name: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let initial = name.trimmingCharacters(in: .whitespaces).first {
                Text(String(initial).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.accent)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08)))
    }
}

// MARK: - 模型

struct ModelsSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var navigation: SettingsNavigation

    private var modelOptions: [(value: String, label: String)] {
        store.models.providers.flatMap { provider in
            provider.models.map { ("\(provider.id)/\($0)", "\(provider.name) / \($0)") }
        }
    }

    var body: some View {
        Form {
            Section {
                if modelOptions.isEmpty {
                    LabeledContent(L10n.t("models.default")) {
                        Text(L10n.t("models.noProviders")).foregroundStyle(.secondary)
                    }
                } else {
                    Picker(L10n.t("models.default"), selection: $store.models.defaultModel) {
                        ForEach(modelOptions, id: \.value) { option in
                            Text(verbatim: option.label).tag(option.value)
                        }
                    }
                }
            } footer: {
                SettingsFooter(L10n.t("models.byokHint"))
            }

            Section {
                if store.models.providers.isEmpty {
                    Text(L10n.t("models.empty"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach($store.models.providers) { $provider in
                    if navigation.editingProvider == provider.id {
                        ProviderEditor(provider: $provider, navigation: navigation) {
                            commitDraft(into: &provider)
                            navigation.editingProvider = nil
                            navigation.providerTest = nil
                        }
                        // 每个服务商用独立的编辑视图：复用时分段控件等会把上一个服务商的值写到新服务商上
                        .id(provider.id)
                    } else {
                        ProviderRow(provider: provider,
                                    onEdit: { beginEditing(provider) },
                                    onDelete: { store.removeModelProvider(provider.id) })
                    }
                }
            } header: {
                HStack {
                    Text(L10n.t("models.providers"))
                    Spacer()
                    Button {
                        let id = store.addModelProvider()
                        if let provider = store.models.providers.first(where: { $0.id == id }) { beginEditing(provider) }
                    } label: {
                        Label(L10n.t("models.addProvider"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func beginEditing(_ provider: ModelProvider) {
        navigation.modelsDraft = provider.models.joined(separator: "\n")
        navigation.providerTest = nil
        navigation.editingProvider = provider.id
    }

    private func commitDraft(into provider: inout ModelProvider) {
        provider.models = Self.parseModels(navigation.modelsDraft)
        store.normalizeDefaultModel()
    }

    static func parseModels(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// 服务商一行：名称、接口格式、地址与模型数量；未填 Key 时提示
private struct ProviderRow: View {
    let provider: ModelProvider
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: provider.kind == .anthropic ? "a.circle.fill" : "o.circle.fill",
                             tint: provider.kind == .anthropic ? Color(nsColor: .systemBrown) : Color(nsColor: .systemGreen),
                             size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.name.isEmpty ? L10n.t("quicklinks.untitled") : provider.name).fontWeight(.medium)
                    Text(L10n.t(provider.kind == .anthropic ? "models.kind.anthropic" : "models.kind.openai"))
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                    if !provider.hasKey {
                        Text(L10n.t("models.noKey"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(provider.endpoint?.host ?? "—") · \(L10n.t("models.count", provider.models.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help(L10n.t("quicklinks.edit"))
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L10n.t("quicklinks.delete"))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }
}

/// 展开编辑服务商：预设、接口格式、名称、地址、Key、模型列表、测试连接
private struct ProviderEditor: View {
    @Binding var provider: ModelProvider
    @ObservedObject var navigation: SettingsNavigation
    let onDone: () -> Void

    private var presetID: Binding<String> {
        Binding(
            get: {
                let base = provider.apiBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
                return ModelsConfig.presets.first { $0.id != "custom" && $0.apiBase == base && $0.kind == provider.kind }?.id ?? "custom"
            },
            set: { id in
                guard let preset = ModelsConfig.presets.first(where: { $0.id == id }), id != "custom" else { return }
                provider.kind = preset.kind
                provider.name = preset.label
                provider.apiBase = preset.apiBase
                navigation.modelsDraft = preset.model
                navigation.providerTest = nil
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    label(L10n.t("models.form.preset"))
                    Picker("", selection: presetID) {
                        ForEach(ModelsConfig.presets, id: \.id) { preset in
                            Text(verbatim: preset.id == "custom" ? L10n.t("models.preset.custom") : preset.label).tag(preset.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                GridRow {
                    label(L10n.t("models.form.kind"))
                    Picker("", selection: $provider.kind) {
                        Text(L10n.t("models.kind.anthropic")).tag(ModelProvider.Kind.anthropic)
                        Text(L10n.t("models.kind.openai")).tag(ModelProvider.Kind.openai)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                GridRow {
                    label(L10n.t("models.form.name"))
                    TextField("", text: $provider.name, prompt: Text(L10n.t("models.form.namePlaceholder")))
                }
                GridRow {
                    label("Base URL")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $provider.apiBase, prompt: Text(verbatim: ModelProvider.defaultBase[provider.kind] ?? ""))
                        Text(L10n.t("models.form.endpoint", provider.endpoint?.absoluteString ?? "—"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                GridRow {
                    label("API Key")
                    SecureField("", text: $provider.apiKey, prompt: Text(verbatim: "sk-..."))
                }
                GridRow {
                    label(L10n.t("models.form.models"))
                    TextField("", text: $navigation.modelsDraft,
                              prompt: Text(verbatim: provider.kind == .anthropic ? "claude-opus-4-8" : "deepseek-chat"),
                              axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .textFieldStyle(.roundedBorder)
            // Form 会把空标签的控件按「标签 + 值」右对齐排版，这里显式隐藏标签、左对齐
            .labelsHidden()
            .multilineTextAlignment(.leading)

            HStack(spacing: 10) {
                testStatus
                Spacer(minLength: 12)
                Button(L10n.t("models.test.run"), action: runTest)
                    .disabled(navigation.providerTest == .running)
                Button(L10n.t("quicklinks.done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
        .padding(.vertical, 6)
    }

    /// 左侧标签列：右对齐成一列（macOS 表单惯例）
    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch navigation.providerTest {
        case .running:
            ProgressView().controlSize(.small)
        case .passed(let model):
            Label(L10n.t("models.test.passed", model), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }

    private func runTest() {
        var candidate = provider
        candidate.models = ModelsSettingsView.parseModels(navigation.modelsDraft)
        navigation.providerTest = .running
        Task { @MainActor in
            do {
                _ = try await AIService.shared.test(candidate)
                navigation.providerTest = .passed(candidate.models.first ?? "")
            } catch {
                navigation.providerTest = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - 关于

struct AboutSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var updater: Updater

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: AppEnvironment.appName).font(.title2.weight(.semibold))
                        Text(L10n.t("about.version", updater.currentVersion, build))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(L10n.t("about.description"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            Section(L10n.t("update.section")) {
                AboutRow(symbol: "arrow.triangle.2.circlepath", tint: Color(nsColor: .systemGreen),
                         title: L10n.t("update.title"), subtitle: updateSubtitle) {
                    updateAction
                }
                if case .downloading(let progress) = updater.status {
                    ProgressView(value: progress).tint(Theme.accent)
                }
                if updater.status != .disabled {
                    Toggle(L10n.t("update.auto"), isOn: $store.autoCheckUpdates)
                }
            }

            Section(L10n.t("about.links")) {
                linkRow(L10n.t("about.website"), AppLinks.website, symbol: "globe", tint: Color(nsColor: .systemBlue))
                linkRow(L10n.t("about.source"), AppLinks.repository, symbol: "chevron.left.forwardslash.chevron.right",
                        tint: Color(nsColor: .darkGray))
                linkRow(L10n.t("about.feedback"), AppLinks.issues, symbol: "bubble.left.and.exclamationmark.bubble.right.fill",
                        tint: Color(nsColor: .systemOrange), subtitle: L10n.t("about.feedbackHelp"))
                linkRow(L10n.t("about.changelog"), AppLinks.releases, symbol: "doc.text.fill", tint: Color(nsColor: .systemTeal))
            }

            Section(L10n.t("about.folders")) {
                folderRow(L10n.t("about.extensionsFolder"), url: ExtensionManager.userExtensionsDirectory,
                          symbol: "puzzlepiece.extension.fill", tint: Color(nsColor: .systemIndigo))
                folderRow(L10n.t("about.dataFolder"), url: SettingsStore.dataDirectory,
                          symbol: "folder.fill", tint: Color(nsColor: .systemBlue))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if updater.status == .idle, !AppEnvironment.isDevelopment { updater.check() }
        }
    }

    private var updateSubtitle: String {
        switch updater.status {
        case .idle: return L10n.t("update.idle", updater.currentVersion)
        case .disabled: return L10n.t("update.disabled")
        case .checking: return L10n.t("update.checking")
        case .upToDate: return L10n.t("update.upToDate")
        case .available(let release): return L10n.t("update.available", release.version)
        case .downloading(let progress): return L10n.t("update.downloading", Int(progress * 100))
        case .installing: return L10n.t("update.installing")
        case .failed(let message): return L10n.t("update.failed", message)
        }
    }

    @ViewBuilder
    private var updateAction: some View {
        switch updater.status {
        case .available(let release):
            HStack(spacing: 8) {
                Button(L10n.t("update.releaseNotes")) { NSWorkspace.shared.open(release.pageURL) }
                    .buttonStyle(.link)
                Button(L10n.t("update.install", release.version)) { updater.install() }
                    .buttonStyle(.borderedProminent)
            }
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        case .disabled:
            EmptyView()
        default:
            Button(L10n.t("update.check")) { updater.check() }
        }
    }

    private func linkRow(_ title: String, _ url: URL, symbol: String, tint: Color, subtitle: String? = nil) -> some View {
        AboutRow(symbol: symbol, tint: tint, title: title,
                 subtitle: subtitle ?? url.absoluteString.replacingOccurrences(of: "https://", with: "")) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.t("about.open"))
        }
    }

    private func folderRow(_ title: String, url: URL, symbol: String, tint: Color) -> some View {
        AboutRow(symbol: symbol, tint: tint, title: title,
                 subtitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
            Button {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.t("about.showInFinder"))
        }
    }
}

/// 关于页的一行：彩色图标、标题、灰色说明，右侧操作
private struct AboutRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.vertical, 7)
    }
}

// MARK: - 扩展

struct ExtensionsSettingsView: View {
    enum Page: String, CaseIterable {
        case installed, store
    }

    @ObservedObject var store: SettingsStore
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var market = ExtensionStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                PageTab(title: L10n.t("extensions.page.installed"), count: BuiltinExtensions.all.count + manager.extensions.count,
                        badge: market.updates.count, selected: navigation.extensionsPage == .installed) {
                    navigation.extensionsPage = .installed
                }
                PageTab(title: L10n.t("extensions.page.store"), count: nil, badge: 0,
                        selected: navigation.extensionsPage == .store) {
                    navigation.extensionsPage = .store
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)

            Form {
                switch navigation.extensionsPage {
                case .installed: installed
                case .store: storeList
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            manager.reload()
            market.refresh(maxAge: 300)
        }
    }

    @ViewBuilder private var installed: some View {
        let updates = market.updates
        if !updates.isEmpty {
            Section {
                HStack {
                    Label(L10n.t("store.updatesAvailable", updates.count), systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Button(L10n.t("store.updateAll")) { market.updateAll() }
                }
            }
        }

        Section {
            ForEach(BuiltinExtensions.all, id: \.id) { ext in
                BuiltinExtensionRow(ext: ext, store: store)
            }
            if manager.extensions.isEmpty {
                HStack {
                    Text(L10n.t("extensions.empty")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("extensions.browseStore")) { navigation.extensionsPage = .store }
                }
            }
            // 内置的在前
            ForEach(manager.extensions.filter { $0.source == .builtin } + manager.extensions.filter { $0.source != .builtin }, id: \.id) { ext in
                ExtensionRow(ext: ext, store: store, market: market, navigation: navigation)
            }
        } footer: {
            SettingsFooter(L10n.t("extensions.footer"))
        }

        Section {
            HStack {
                Button(L10n.t("extensions.openFolder")) {
                    let url = ExtensionManager.userExtensionsDirectory
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
                Button(L10n.t("extensions.reload")) {
                    manager.reload()
                    store.onExtensionsChange?()
                }
                Spacer()
                Link(L10n.t("extensions.develop"), destination: AppLinks.extensionsDocs)
            }
        }
    }

    @ViewBuilder private var storeList: some View {
        Section {
            switch market.loadState {
            case .loading where market.entries.isEmpty, .idle:
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            case .failed(let message) where market.entries.isEmpty:
                HStack {
                    Text(L10n.t("store.loadFailed", message)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t("store.retry")) { market.refresh() }
                }
            default:
                ForEach(market.entries) { entry in
                    StoreEntryRow(entry: entry, manager: manager, market: market)
                }
            }
        } footer: {
            SettingsFooter(L10n.t("store.footer"))
        }

        Section {
            HStack {
                Button(L10n.t("store.refresh")) { market.refresh() }
                    .disabled(market.loadState == .loading)
                Spacer()
                Link(L10n.t("store.submit"), destination: AppLinks.submitExtension)
                Link(L10n.t("extensions.develop"), destination: AppLinks.extensionsDocs)
            }
        }
    }
}

/// 扩展页顶部的标签：选中时浅色圆角底，可带数量和更新角标
private struct PageTab: View {
    let title: String
    let count: Int?
    /// 有更新的扩展数，大于 0 时显示红点数字
    let badge: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .fontWeight(selected ? .semibold : .regular)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 插件市场里的一个插件：图标、介绍，安装 / 更新 / 已安装
private struct StoreEntryRow: View {
    let entry: StoreEntry
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var market: ExtensionStore

    private var installed: SpotcatExtension? { manager.extensions.first { $0.id == entry.id } }

    var body: some View {
        HStack(spacing: 12) {
            StoreIcon(entry: entry)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name.text).font(.body.weight(.medium))
                    Badge(text: L10n.t(entry.official == true ? "extensions.official" : "extensions.community"))
                    Text(verbatim: "v\(entry.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let description = entry.description?.text {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    if let features = entry.features, !features.isEmpty {
                        Text(L10n.t("extensions.features", features.count))
                    }
                    if let author = entry.author {
                        Text(L10n.t("extensions.author", author))
                    }
                    if let permissions = entry.permissions, !permissions.isEmpty {
                        let names = permissions.map { L10n.t("extensions.permission.\($0)") }
                        Text(L10n.t("extensions.permissions", names.joined(separator: L10n.t("extensions.listSeparator"))))
                    }
                    if let homepage = entry.homepage {
                        Link(L10n.t("store.homepage"), destination: homepage)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                if case .failed(let message) = market.tasks[entry.id] {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }

            Spacer()
            action
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var action: some View {
        switch market.tasks[entry.id] {
        case .downloading(let progress):
            ProgressView(value: progress).frame(width: 60)
        case .installing:
            ProgressView().controlSize(.small)
        default:
            if let installed {
                if installed.source.isStore, Version(entry.version) > Version(installed.manifest.version) {
                    Button(L10n.t("store.update")) { market.install(entry) }
                } else {
                    // 本地 / 开发中的同 id 插件不会被市场覆盖
                    Text(L10n.t(installed.source.isStore ? "store.installed" : "store.installedLocally"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !entry.isCompatible {
                Text(L10n.t("store.requiresApp", entry.minAppVersion ?? ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button(L10n.t("store.install")) { market.install(entry) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// 插件目录里的图标："sf:" 图标本地绘制，图片从 CDN 加载
private struct StoreIcon: View {
    let entry: StoreEntry

    var body: some View {
        if let icon = entry.icon, icon.hasPrefix("sf:") {
            Image(nsImage: ExtensionIcon.symbolTile(String(icon.dropFirst(3)), color: NSColor(hex: entry.iconColor) ?? .systemBlue))
                .resizable()
        } else if let icon = entry.icon, let url = URL(string: icon) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06))
            }
        } else {
            Image(nsImage: ExtensionIcon.symbolTile("puzzlepiece.extension.fill", color: NSColor(hex: entry.iconColor) ?? .systemBlue))
                .resizable()
        }
    }
}

/// 一个扩展：总开关 + 可展开的功能列表
private struct ExtensionRow: View {
    let ext: SpotcatExtension
    @ObservedObject var store: SettingsStore
    @ObservedObject var market: ExtensionStore
    @ObservedObject var navigation: SettingsNavigation

    private var confirmingUninstall: Binding<Bool> {
        Binding(
            get: { navigation.uninstallingExtension == ext.id },
            set: { if !$0 { navigation.uninstallingExtension = nil } }
        )
    }

    private var enabled: Bool { store.isExtensionEnabled(ext.id) }

    var body: some View {
        DisclosureGroup {
            ForEach(ext.features, id: \.id) { feature in
                FeatureRow(feature: feature, ext: ext, store: store)
            }
        } label: {
            HStack(spacing: 12) {
                Image(nsImage: ExtensionIcon.image(for: ext))
                    .resizable()
                    .frame(width: 32, height: 32)
                    .opacity(enabled ? 1 : 0.4)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ext.manifest.name).font(.body.weight(.medium))
                        Badge(text: sourceLabel)
                        Text(verbatim: "v\(ext.manifest.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let description = ext.manifest.description {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        Text(L10n.t("extensions.features", ext.features.count))
                        if let author = ext.manifest.author {
                            Text(L10n.t("extensions.author", author))
                        }
                        if let permissions = ext.manifest.permissions, !permissions.isEmpty {
                            let names = permissions.map { L10n.t("extensions.permission.\($0)") }
                            Text(L10n.t("extensions.permissions", names.joined(separator: L10n.t("extensions.listSeparator"))))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                if case .downloading(let progress) = market.tasks[ext.id] {
                    ProgressView(value: progress).frame(width: 60)
                } else if market.hasUpdate(ext), let entry = market.entry(id: ext.id) {
                    Button(L10n.t("store.updateTo", entry.version)) { market.install(entry) }
                }

                Menu {
                    Button(L10n.t("extensions.reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([ext.directory])
                    }
                    if ext.source != .dev && ext.source != .builtin {
                        Divider()
                        Button(L10n.t("extensions.uninstall"), role: .destructive) { navigation.uninstallingExtension = ext.id }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .confirmationDialog(L10n.t("extensions.uninstallConfirm", ext.manifest.name), isPresented: confirmingUninstall) {
                    Button(L10n.t("extensions.uninstall"), role: .destructive) { market.uninstall(ext) }
                } message: {
                    Text(L10n.t("extensions.uninstallMessage"))
                }

                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { store.setExtension(ext.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.vertical, 4)
        }
    }
}

/// 随 App 内置的原生扩展：只有启用开关，不能卸载
private struct BuiltinExtensionRow: View {
    let ext: BuiltinExtension
    @ObservedObject var store: SettingsStore

    var body: some View {
        let enabled = !ext.canDisable || store.isExtensionEnabled(ext.id)
        HStack(spacing: 12) {
            Image(nsImage: ExtensionIcon.symbolTile(ext.icon.symbol, color: ext.icon.color))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(enabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ext.name).font(.body.weight(.medium))
                    Badge(text: L10n.t("extensions.builtin"))
                }
                Text(ext.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if ext.canDisable {
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { store.setExtension(ext.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(.vertical, 4)
        // 和可展开的扩展行对齐
        .padding(.leading, 20)
    }
}

private extension ExtensionRow {
    var sourceLabel: String {
        switch ext.source {
        case .store(let official): return L10n.t(official ? "extensions.official" : "extensions.community")
        case .local: return L10n.t("extensions.local")
        case .dev: return L10n.t("extensions.dev")
        case .builtin: return L10n.t("extensions.builtin")
        }
    }
}

private struct FeatureRow: View {
    let feature: ExtensionFeatureRef
    let ext: SpotcatExtension
    @ObservedObject var store: SettingsStore

    var body: some View {
        let extensionEnabled = store.isExtensionEnabled(ext.id)
        HStack(spacing: 10) {
            Image(nsImage: ExtensionIcon.image(for: ext, feature: feature.feature))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(feature.feature.title)
                    if feature.hasMatchRules {
                        Badge(text: L10n.t("extensions.matches"))
                    }
                }
                if let keywords = feature.feature.keywords, !keywords.isEmpty {
                    Text(L10n.t("extensions.keywords", keywords.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { store.isFeatureEnabled(feature) },
                set: { store.setFeature(feature.id, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!extensionEnabled)
        }
        .opacity(extensionEnabled ? 1 : 0.5)
        .padding(.leading, 30)
    }
}

private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - 快捷链接

struct QuicklinksSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("quicklinks.searchEngine"), selection: $store.defaultSearchEngine) {
                    Text(L10n.t("quicklinks.none")).tag("")
                    ForEach(store.quicklinks.filter(\.acceptsQuery)) { link in
                        Text(verbatim: link.name.isEmpty ? link.keyword : link.name).tag(link.id)
                    }
                }
            } footer: {
                SettingsFooter(L10n.t("quicklinks.searchEngineFooter"))
            }

            Section {
                ForEach($store.quicklinks) { $link in
                    if navigation.editingQuicklink == link.id {
                        QuicklinkEditor(link: $link) { navigation.editingQuicklink = nil }
                    } else {
                        QuicklinkRow(link: link,
                                     onEdit: { navigation.editingQuicklink = link.id },
                                     onDelete: { store.removeQuicklink(link.id) })
                    }
                }
            } header: {
                HStack {
                    Text(L10n.t("settings.tab.quicklinks"))
                    Spacer()
                    Button(L10n.t("quicklinks.reset")) {
                        navigation.editingQuicklink = nil
                        store.resetQuicklinks()
                    }
                    .buttonStyle(.borderless)
                    Button {
                        navigation.editingQuicklink = store.addQuicklink()
                    } label: {
                        Label(L10n.t("quicklinks.add"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                SettingsFooter(L10n.t("quicklinks.footer"))
            }
        }
        .formStyle(.grouped)
    }
}

/// 列表中的一行：图标、名称、关键词、网址（只读），右侧编辑/删除
private struct QuicklinkRow: View {
    let link: Quicklink
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            QuicklinkIcon(host: link.host)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(link.name.isEmpty ? L10n.t("quicklinks.untitled") : link.name)
                        .fontWeight(.medium)
                    if !link.keyword.isEmpty {
                        Text(link.keyword)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(link.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("quicklinks.edit"))
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.t("quicklinks.delete"))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }
}

/// 展开编辑的一行
private struct QuicklinkEditor: View {
    @Binding var link: Quicklink
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(L10n.t("quicklinks.name")).foregroundStyle(.secondary)
                    TextField("", text: $link.name, prompt: Text(verbatim: "GitHub"))
                }
                GridRow {
                    Text(L10n.t("quicklinks.keyword")).foregroundStyle(.secondary)
                    TextField("", text: $link.keyword, prompt: Text(verbatim: "gh"))
                        .frame(maxWidth: 140)
                }
                GridRow {
                    Text(L10n.t("quicklinks.url")).foregroundStyle(.secondary)
                    TextField("", text: $link.url, prompt: Text(verbatim: "https://example.com/search?q={query}"))
                }
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()

            HStack {
                QuicklinkIcon(host: link.host)
                Text(link.resolvedURL(query: "spotcat")?.absoluteString ?? "")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L10n.t("quicklinks.done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct QuicklinkIcon: View {
    let host: String?
    @ObservedObject var cache = FaviconCache.shared

    var body: some View {
        Group {
            if let host, let favicon = cache.icon(for: host) {
                Image(nsImage: favicon).resizable()
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}
