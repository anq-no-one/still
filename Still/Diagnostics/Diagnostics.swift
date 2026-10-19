import CryptoKit
import Foundation
import Observation

/// A closed set of names. Nothing a user wrote or a recording contains can
/// become an event, because there is no free-text field to put it in.
enum DiagnosticEvent: String, Codable, CaseIterable, Sendable {
    case recordingFailed
    case recordingRecovered
    case transcriptionFailed
    case modelDownloadFailed
    case modelDownloadVerificationFailed
    case syncFailed
    case exportFailed
    case libraryUnlockFailed
}

struct DiagnosticReport: Codable, Equatable, Sendable {
    let event: DiagnosticEvent
    let appVersion: String
    let systemVersion: String
    let deviceClass: String
    let occurredAt: Date
    let durationSeconds: Int?
}

protocol DiagnosticsSettingsStore: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool)
}

protocol DiagnosticsSink: Sendable {
    func send(_ report: DiagnosticReport) async
}

/// Off until the user turns it on, and off again the moment they change their
/// mind. A report carries the name of what failed and the shape of the device,
/// never what was said, written, searched for, or stored.
@MainActor
@Observable
final class Diagnostics {
    private let settings: DiagnosticsSettingsStore
    private let sink: DiagnosticsSink
    private let environment: () -> (appVersion: String, systemVersion: String, deviceClass: String)
    private let now: () -> Date

    private(set) var isEnabled: Bool
    let journal: DiagnosticJournal
    let developer: DeveloperDiagnostics
    private let bundleContext: @MainActor () -> [String: String]

    init(
        settings: DiagnosticsSettingsStore,
        sink: DiagnosticsSink,
        journal: DiagnosticJournal = DiagnosticJournal(
            fileURL: URL.temporaryDirectory.appending(path: "still-journal-\(UUID().uuidString).jsonl"),
            key: SymmetricKey(size: .bits256)
        ),
        developer: DeveloperDiagnostics = DeveloperDiagnostics(),
        bundleContext: @escaping @MainActor () -> [String: String] = { [:] },
        environment: @escaping () -> (appVersion: String, systemVersion: String, deviceClass: String) = Diagnostics.systemEnvironment,
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.sink = sink
        self.journal = journal
        self.developer = developer
        self.bundleContext = bundleContext
        self.environment = environment
        self.now = now
        isEnabled = settings.isEnabled()
    }

    func debugBundleBuilder(library: Library) -> DebugBundleBuilder? {
        guard developer.allowsDebugBundle else { return nil }
        return DebugBundleBuilder(library: library, journal: journal, developer: developer, context: bundleContext)
    }

    func enable() {
        isEnabled = true
        settings.setEnabled(true)
    }

    func disable() {
        isEnabled = false
        settings.setEnabled(false)
    }

    func record(_ event: DiagnosticEvent, duration: TimeInterval? = nil) async {
        guard isEnabled else { return }

        let environment = environment()
        await sink.send(
            DiagnosticReport(
                event: event,
                appVersion: environment.appVersion,
                systemVersion: environment.systemVersion,
                deviceClass: environment.deviceClass,
                occurredAt: now(),
                durationSeconds: duration.map { Int($0.rounded()) }
            )
        )
    }

    nonisolated static func systemEnvironment() -> (appVersion: String, systemVersion: String, deviceClass: String) {
        (
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceClass: deviceClass
        )
    }

    private nonisolated static var deviceClass: String {
        #if os(macOS)
        "mac"
        #else
        "ios"
        #endif
    }
}

struct UserDefaultsDiagnosticsSettings: DiagnosticsSettingsStore, @unchecked Sendable {
    private let key = "still.diagnostics.enabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled() -> Bool {
        defaults.bool(forKey: key)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: key)
    }
}
