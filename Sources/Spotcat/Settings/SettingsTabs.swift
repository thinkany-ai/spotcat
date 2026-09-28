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
                        if store.shortcut != .default {
                            Button {
                                store.updateShortcut(.default)
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
                }
            }

            Section {
                Toggle(L10n.t("settings.results.recents"), isOn: $store.showRecents)
                Toggle(L10n.t("settings.results.best"), isOn: $store.showBestMatches)
                Toggle(L10n.t("settings.results.suggestions"), isOn: $store.showSuggestions)
                LabeledContent {
                    Button(L10n.t("settings.results.clear"), action: store.clearUsageHistory)
                } label: {
                    Text(L10n.t("settings.results.history"))
                    Text(L10n.t("settings.results.historyHelp"))
                }
            } header: {
                Text(L10n.t("settings.results"))
            } footer: {
                SettingsFooter(L10n.t("settings.results.footer"))
            }

            Section(L10n.t("settings.window")) {
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
                    .background(Color.accentColor)
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

// MARK: - AI

struct AISettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("settings.ai.provider"), selection: Binding(
                    get: { store.ai.preset },
                    set: { store.applyAIPreset($0) }
                )) {
                    ForEach(AIConfig.presets, id: \.id) { preset in
                        Text(verbatim: preset.id == AIConfig.customPresetID ? L10n.t("settings.ai.custom") : preset.name)
                            .tag(preset.id)
                    }
                }
                TextField(L10n.t("settings.ai.baseURL"), text: $store.ai.baseURL, prompt: Text(verbatim: "https://api.example.com/v1"))
                SecureField(L10n.t("settings.ai.apiKey"), text: $store.ai.apiKey, prompt: Text(verbatim: "sk-..."))
                TextField(L10n.t("settings.ai.model"), text: $store.ai.model)
                LabeledContent(L10n.t("settings.ai.connection")) {
                    HStack(spacing: 10) {
                        testStatus
                        Button(L10n.t("settings.ai.test"), action: store.testAI)
                            .disabled(!store.ai.isConfigured || store.aiTestStatus == .testing)
                    }
                }
            } footer: {
                SettingsFooter(L10n.t("settings.ai.footer"))
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch store.aiTestStatus {
        case .idle:
            EmptyView()
        case .testing:
            Text(L10n.t("settings.ai.testing")).foregroundStyle(.secondary)
        case .success(let reply):
            Label(L10n.t("settings.ai.testOK", String(reply.prefix(40))), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(L10n.t("settings.ai.testFailed", message), systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 关于

struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

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
                        Text(L10n.t("about.version", version, build))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(L10n.t("about.description"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section(L10n.t("about.folders")) {
                folderRow(L10n.t("about.extensionsFolder"), url: ExtensionManager.userExtensionsDirectory)
                folderRow(L10n.t("about.dataFolder"), url: SettingsStore.dataDirectory)
            }
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ title: String, url: URL) -> some View {
        LabeledContent {
            Button(L10n.t("about.showInFinder")) {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            Text(title)
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .textSelection(.enabled)
        }
    }
}

// MARK: - 扩展

struct ExtensionsSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var manager: ExtensionManager

    var body: some View {
        Form {
            Section {
                if manager.extensions.isEmpty {
                    Text(L10n.t("extensions.empty")).foregroundStyle(.secondary)
                }
                ForEach(manager.extensions, id: \.id) { ext in
                    ExtensionRow(ext: ext, store: store)
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
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.reload() }
    }
}

/// 一个扩展：总开关 + 可展开的功能列表
private struct ExtensionRow: View {
    let ext: SpotcatExtension
    @ObservedObject var store: SettingsStore

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
                        Badge(text: ext.isBuiltIn ? L10n.t("extensions.builtIn") : L10n.t("extensions.local"))
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

    var body: some View {
        Form {
            Section {
                ForEach($store.quicklinks) { $link in
                    HStack(spacing: 8) {
                        QuicklinkIcon(host: link.host)
                        TextField(L10n.t("quicklinks.name"), text: $link.name, prompt: Text(L10n.t("quicklinks.name")))
                            .frame(width: 110)
                        TextField(L10n.t("quicklinks.keyword"), text: $link.keyword, prompt: Text(L10n.t("quicklinks.keyword")))
                            .frame(width: 70)
                        TextField(L10n.t("quicklinks.url"), text: $link.url, prompt: Text(verbatim: "https://example.com/search?q={query}"))
                        Button {
                            store.removeQuicklink(link.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button(L10n.t("quicklinks.add"), action: store.addQuicklink)
                    Spacer()
                    Button(L10n.t("quicklinks.reset"), action: store.resetQuicklinks)
                }
            } footer: {
                SettingsFooter(L10n.t("quicklinks.footer"))
            }

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
        }
        .formStyle(.grouped)
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
