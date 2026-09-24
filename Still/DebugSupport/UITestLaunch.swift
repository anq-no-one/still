#if DEBUG
import Foundation
import Security

enum UITestLaunch {
    static let resetKey = "STILL_UI_TEST_RESET"
    static let audioFixtureKey = "STILL_AUDIO_FIXTURE"
    static let modelRootKey = "STILL_MODEL_ROOT"
    static let handOverFixtureKey = "STILL_HAND_OVER_FIXTURE"
    static let allowAIToolsArgument = "--allow-ai-tools"

    static var allowsAITools: Bool {
        ProcessInfo.processInfo.arguments.contains(allowAIToolsArgument)
    }

    static var modelRoot: URL? {
        ProcessInfo.processInfo.environment[modelRootKey].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static var audioFixture: URL? {
        guard let name = ProcessInfo.processInfo.environment[audioFixtureKey] else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "fixture.caf")
    }

    static var handedOverFixture: URL? {
        guard let name = ProcessInfo.processInfo.environment[handOverFixtureKey],
              let fixture = Bundle.main.url(forResource: name, withExtension: "fixture.mov")
        else { return nil }

        let inbox = URL.temporaryDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "Still")-Inbox")
        let copy = inbox.appending(path: "Team meeting.mov")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        guard (try? FileManager.default.copyItem(at: fixture, to: copy)) != nil else { return nil }
        return copy
    }

    static func resetIfRequested(keychainService: String) {
        guard ProcessInfo.processInfo.environment[resetKey] == "1" else { return }

        let fileManager = FileManager.default
        let still = URL.applicationSupportDirectory.appending(path: "Still", directoryHint: .isDirectory)
        if let contents = try? fileManager.contentsOfDirectory(at: .applicationSupportDirectory, includingPropertiesForKeys: nil) {
            contents.filter { $0.lastPathComponent != "Still" }.forEach { try? fileManager.removeItem(at: $0) }
        }
        if let contents = try? fileManager.contentsOfDirectory(at: still, includingPropertiesForKeys: nil) {
            contents.filter { $0.lastPathComponent != "Models" }.forEach { try? fileManager.removeItem(at: $0) }
        }

        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }

        for dataProtection in [true, false] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecUseDataProtectionKeychain as String: dataProtection,
            ] as CFDictionary)
        }
    }
}
#endif
