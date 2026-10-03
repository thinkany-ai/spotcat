import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 录制状态放在 ObservableObject 里：Command Line Tools 不带 SwiftUI 宏插件，@State 无法编译
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }
        store.shortcutError = nil
        store.setRecording(true)
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                self.stop()
                return nil
            }
            guard let shortcut = Shortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            self.stop()
            self.store.updateShortcut(shortcut)
            return nil
        }
    }

    func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        store.setRecording(false)
    }
}

/// 点击后进入录制状态，按下组合键即保存；Esc 取消
struct ShortcutRecorder: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var model: ShortcutRecorderModel

    var body: some View {
        Button {
            model.toggle()
        } label: {
            Text(model.isRecording ? L10n.t("settings.shortcut.recording") : store.shortcut.displayString)
                .frame(minWidth: 110)
        }
        .onDisappear(perform: model.stop)
    }
}

// MARK: - 功能快捷键

/// 设置 › 扩展 里功能快捷键的录制状态：同一时间只录一个。Esc 取消，⌫ 清除
final class FeatureShortcutRecorder: ObservableObject {
    static let shared = FeatureShortcutRecorder()

    enum Kind { case chord, global }

    struct Recording: Equatable {
        let id: String
        let kind: Kind
    }

    @Published private(set) var recording: Recording?
    /// 目标 id → 上次保存失败的原因
    @Published private(set) var errors: [String: String] = [:]
    private var monitor: Any?

    func isRecording(_ id: String, _ kind: Kind) -> Bool {
        recording == Recording(id: id, kind: kind)
    }

    func toggle(_ id: String, _ kind: Kind) {
        if isRecording(id, kind) { stop() } else { start(id, kind) }
    }

    func clear(_ id: String, _ kind: Kind) {
        stop()
        errors[id] = nil
        let shortcuts = FeatureShortcuts.shared
        _ = kind == .chord ? shortcuts.setChordKey(nil, for: id) : shortcuts.setHotKey(nil, for: id)
    }

    private func start(_ id: String, _ kind: Kind) {
        stop()
        errors[id] = nil
        recording = Recording(id: id, kind: kind)
        // 录全局快捷键时暂停已注册的快捷键，否则按下它们会直接触发
        if kind == .global { FeatureShortcuts.shared.setRecording(true) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event, id: id, kind: kind)
            return nil
        }
    }

    private func handle(_ event: NSEvent, id: String, kind: Kind) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Escape) { return stop() }
        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            return clear(id, kind)
        }
        let shortcuts = FeatureShortcuts.shared
        let error: String?
        switch kind {
        case .chord:
            // 二级键只要一个字符，修饰键由主快捷键决定
            guard let key = event.characters(byApplyingModifiers: [])?.lowercased(), key.count == 1,
                  let scalar = key.unicodeScalars.first, !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !CharacterSet.controlCharacters.contains(scalar) else { return NSSound.beep() }
            error = shortcuts.setChordKey(key, for: id)
        case .global:
            guard let shortcut = Shortcut(event: event) else { return NSSound.beep() }
            stop()
            error = shortcuts.setHotKey(shortcut, for: id)
        }
        stop()
        errors[id] = error
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording?.kind == .global { FeatureShortcuts.shared.setRecording(false) }
        recording = nil
    }
}

/// 一个功能的两个快捷键按钮：二级键、全局快捷键。右键可清除
struct FeatureShortcutControls: View {
    let id: String
    /// 放在描述下面时左对齐，放在行尾时右对齐
    var alignment: HorizontalAlignment = .trailing
    @ObservedObject var shortcuts = FeatureShortcuts.shared
    @ObservedObject var recorder = FeatureShortcutRecorder.shared

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 6) {
                button(.chord,
                       value: shortcuts.chordKeys[id].map(FeatureShortcuts.chordDisplay),
                       placeholder: L10n.t("shortcuts.chord.placeholder", SettingsStore.shared.shortcut.displayString),
                       recordingText: L10n.t("shortcuts.recordingKey"),
                       help: L10n.t("shortcuts.chord.help", SettingsStore.shared.shortcut.displayString))
                button(.global,
                       value: shortcuts.hotKeys[id]?.displayString,
                       placeholder: L10n.t("shortcuts.global.placeholder"),
                       recordingText: L10n.t("shortcuts.recordingShortcut"),
                       help: L10n.t("shortcuts.global.help"))
                detachedToggle
            }
            if let error = recorder.errors[id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// 全局快捷键是否在独立窗口打开；设了全局快捷键且支持独立窗口时才可用，不可用时占位保持对齐
    @ViewBuilder private var detachedToggle: some View {
        let available = shortcuts.hotKeys[id] != nil && LauncherController.supportsDetached(id)
        let isOn = shortcuts.detachedTargets.contains(id)
        Button {
            shortcuts.setDetached(!isOn, for: id)
        } label: {
            Image(systemName: isOn ? "macwindow.on.rectangle" : "macwindow")
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(L10n.t(isOn ? "shortcuts.detached.on" : "shortcuts.detached.off"))
        .opacity(available ? 1 : 0)
        .disabled(!available)
    }

    private func button(_ kind: FeatureShortcutRecorder.Kind, value: String?, placeholder: String,
                        recordingText: String, help: String) -> some View {
        let isRecording = recorder.isRecording(id, kind)
        return Button {
            recorder.toggle(id, kind)
        } label: {
            Text(isRecording ? recordingText : value ?? placeholder)
                .font(.callout.monospacedDigit())
                .foregroundStyle(value == nil && !isRecording ? .secondary : .primary)
                .frame(minWidth: 96)
        }
        .controlSize(.small)
        .help(help)
        .contextMenu {
            if value != nil {
                Button(L10n.t("shortcuts.clear")) { recorder.clear(id, kind) }
            }
        }
        .onDisappear { if isRecording { recorder.stop() } }
    }
}
