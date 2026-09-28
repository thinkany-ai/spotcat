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
