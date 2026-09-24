#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// A Carbon hot key, because it reaches Still while another app is frontmost
/// without asking for Accessibility or Input Monitoring access.
@MainActor
final class GlobalRecordingShortcut: HotKeyRegistrar {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: @MainActor () -> Void = {}

    func register(_ combo: KeyCombo, action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        self.action = action
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x53_54_4C_4C), id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    private func installHandler() {
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
    }
}
#endif
