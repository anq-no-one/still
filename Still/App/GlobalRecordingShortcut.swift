#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// A Carbon hot key, because it reaches Still while another app is frontmost
/// without asking for Accessibility or Input Monitoring access.
@MainActor
final class GlobalRecordingShortcut {
    static let keyCode = UInt32(kVK_ANSI_R)
    static let modifiers = UInt32(cmdKey | optionKey)

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        register()
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    private func register() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let shortcut = Unmanaged<GlobalRecordingShortcut>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in shortcut.action() }
                return noErr
            },
            1,
            &type,
            context,
            &handler
        )

        let id = EventHotKeyID(signature: OSType(0x53_54_4C_4C), id: 1)
        RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
#endif
