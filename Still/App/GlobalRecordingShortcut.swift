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
    private nonisolated let id: UInt32

    init(id: UInt32 = 1) {
        self.id = id
    }

    func register(_ combo: KeyCombo, action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        self.action = action
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x53_54_4C_4C), id: id)
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
            { _, event, context in
                guard let context else { return noErr }
                var pressed = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                let shortcut = Unmanaged<GlobalRecordingShortcut>.fromOpaque(context).takeUnretainedValue()
                guard pressed.id == shortcut.id else { return OSStatus(eventNotHandledErr) }
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
