import CryptoKit
import Foundation
import Observation

protocol SyncSettingsStore: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool)
    func lastSyncedAt() -> Date?
    func setLastSyncedAt(_ date: Date)
}

/// Sync is on for a new install and only ever sends sealed payloads to the
/// user's own iCloud. Turning it off keeps every Recording on this device.
@MainActor
@Observable
final class SyncEngine {
    private let library: Library
    private let transport: SyncTransport
    private let settings: SyncSettingsStore
    private let deviceID: UUID
    private let now: () -> Date

    private(set) var isEnabled: Bool
    private(set) var lastFailure: String?
    private(set) var lastSyncedAt: Date?

    init(
        library: Library,
        transport: SyncTransport,
        settings: SyncSettingsStore,
        deviceID: UUID = UUID(),
        now: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.transport = transport
        self.settings = settings
        self.deviceID = deviceID
        self.now = now
        isEnabled = settings.isEnabled()
        lastSyncedAt = settings.lastSyncedAt()
    }

    static let whatLeavesTheDevice = String(localized: """
        Sync sends your recordings to your own iCloud account, encrypted on this device \
        first. Apple stores only ciphertext: no transcript, note, audio, or key ever leaves in \
        readable form. Text and notes arrive on your other devices before the audio finishes.
        """)

    func enable() {
        isEnabled = true
        settings.setEnabled(true)
    }

    func disable() {
        isEnabled = false
        settings.setEnabled(false)
    }

    func syncIfEnabled() async {
        guard isEnabled else { return }
        await sync()
    }

    func sync() async {
        guard isEnabled else {
            lastFailure = SyncError.disabled.localizedDescription
            return
        }

        let correlationID = UUID()
        library.journal?.record(.syncStarted, correlationID: correlationID)
        do {
            try await pull()
            try await push()
            let stamp = now()
            settings.setLastSyncedAt(stamp)
            lastSyncedAt = stamp
            lastFailure = nil
            library.journal?.record(.syncFinished, correlationID: correlationID)
        } catch {
            lastFailure = error.localizedDescription
            library.journal?.fail(.syncFailed, error: error, correlationID: correlationID)
        }
    }

    private func pull() async throws {
        for change in try await transport.pull(since: lastSyncedAt) where change.deviceID != deviceID {
            switch change.kind {
            case .recording:
                guard let remote = try? library.openSyncPayload(change.sealedRecording) else { continue }
                try library.applyRemote(remote)
            case .project:
                guard let remote = try? library.openProjectSyncPayload(change.sealedRecording) else { continue }
                try library.applyRemote(remote)
            }
        }
    }

    private func push() async throws {
        let recordings = try library.recordingsInEveryProject.filter(\.isProjectConfirmed).map { recording in
            SyncChange(
                recordingID: recording.id,
                updatedAt: recording.updatedAt,
                deviceID: deviceID,
                sealedRecording: try library.sealForSync(recording)
            )
        }
        let projects = try library.storedProjects.map { project in
            SyncChange(
                recordingID: project.id,
                updatedAt: project.updatedAt,
                deviceID: deviceID,
                sealedRecording: try library.sealForSync(project),
                kind: .project
            )
        }
        let changes = recordings + projects

        guard !changes.isEmpty else { return }
        try await transport.push(changes)
    }
}

struct UserDefaultsSyncSettings: SyncSettingsStore, @unchecked Sendable {
    private let enabledKey = "still.sync.enabled"
    private let syncedKey = "still.sync.lastSyncedAt"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled() -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: enabledKey)
    }

    func lastSyncedAt() -> Date? {
        defaults.object(forKey: syncedKey) as? Date
    }

    func setLastSyncedAt(_ date: Date) {
        defaults.set(date, forKey: syncedKey)
    }
}
