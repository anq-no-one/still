#if os(macOS)
import Carbon.HIToolbox
import Foundation
import Observation

struct KeyCombo: Codable, Equatable, Sendable {
    static let standard = KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey), key: "R")

    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    var displayText: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key.uppercased()
    }

    var hasCommandOptionOrControl: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }
}

enum ShortcutProblem: Error, Equatable, LocalizedError {
    case needsModifier
    case reservedBySystem
    case takenByAnotherApp

    var errorDescription: String? {
        switch self {
        case .needsModifier:
            String(localized: "Use Command, Option, or Control with the key, so typing in other apps never starts a recording.")
        case .reservedBySystem:
            String(localized: "macOS already uses this shortcut. Choose another one or turn it off in System Settings → Keyboard → Keyboard Shortcuts.")
        case .takenByAnotherApp:
            String(localized: "Another app already uses this shortcut. Choose another one.")
        }
    }
}

@MainActor
protocol HotKeyRegistrar: AnyObject {
    func register(_ combo: KeyCombo, action: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

protocol SystemShortcutSource: Sendable {
    func reservedCombos() -> [KeyCombo]
}

protocol ShortcutStore: Sendable {
    func load() -> KeyCombo?
    func save(_ combo: KeyCombo)
}

@MainActor
@Observable
final class RecordingShortcut {
    private let registrar: HotKeyRegistrar
    private let system: SystemShortcutSource
    private let store: ShortcutStore
    private let action: @MainActor () -> Void

    private(set) var combo: KeyCombo?
    private(set) var problem: ShortcutProblem?

    init(
        registrar: HotKeyRegistrar,
        system: SystemShortcutSource,
        store: ShortcutStore,
        action: @escaping @MainActor () -> Void
    ) {
        self.registrar = registrar
        self.system = system
        self.store = store
        self.action = action
        let saved = store.load() ?? .standard
        if registrar.register(saved, action: action) {
            combo = saved
        } else {
            problem = .takenByAnotherApp
        }
    }

    @discardableResult
    func change(to candidate: KeyCombo) -> Bool {
        if let problem = check(candidate) {
            self.problem = problem
            return false
        }

        registrar.unregister()
        guard registrar.register(candidate, action: action) else {
            if let combo { _ = registrar.register(combo, action: action) }
            problem = .takenByAnotherApp
            return false
        }

        combo = candidate
        problem = nil
        store.save(candidate)
        return true
    }

    func resetToStandard() {
        change(to: .standard)
    }

    private func check(_ candidate: KeyCombo) -> ShortcutProblem? {
        guard candidate.hasCommandOptionOrControl else { return .needsModifier }
        let reserved = system.reservedCombos().contains {
            $0.keyCode == candidate.keyCode && $0.modifiers == candidate.modifiers
        }
        return reserved ? .reservedBySystem : nil
    }
}

struct UserDefaultsShortcutStore: ShortcutStore, @unchecked Sendable {
    private let key = "still.shortcut.toggleRecording"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> KeyCombo? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
    }

    func save(_ combo: KeyCombo) {
        defaults.set(try? JSONEncoder().encode(combo), forKey: key)
    }
}

struct CarbonSystemShortcuts: SystemShortcutSource {
    func reservedCombos() -> [KeyCombo] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? Int
            else { return nil }
            return KeyCombo(keyCode: UInt32(code), modifiers: UInt32(modifiers), key: "")
        }
    }
}
#endif
