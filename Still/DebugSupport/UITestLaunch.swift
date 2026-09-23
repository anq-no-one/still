#if DEBUG
import Foundation
import Security

/// What an end-to-end run asks of a Debug build. Release builds compile none
/// of this, so a shipped Still can neither be wiped nor fed recorded audio.
enum UITestLaunch {
    static let resetKey = "STILL_UI_TEST_RESET"
    static let audioFixtureKey = "STILL_AUDIO_FIXTURE"
    static let modelRootKey = "STILL_MODEL_ROOT"

    /// A simulator run keeps the Model Pack in one folder on the Mac, so the
    /// download happens once rather than on every fresh simulator.
    static var modelRoot: URL? {
        ProcessInfo.processInfo.environment[modelRootKey].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static var audioFixture: URL? {
        guard let name = ProcessInfo.processInfo.environment[audioFixtureKey] else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "fixture.caf")
    }

    /// Starts the run from a first launch: no Library, no keys, no settings.
    static func resetIfRequested(keychainService: String) {
        guard ProcessInfo.processInfo.environment[resetKey] == "1" else { return }

        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(
            at: .applicationSupportDirectory,
            includingPropertiesForKeys: nil
        ) {
            contents.forEach { try? fileManager.removeItem(at: $0) }
        }

        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }

        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ] as CFDictionary)
    }
}
#endif
