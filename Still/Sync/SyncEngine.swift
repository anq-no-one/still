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

        do {
            try await pull()
            try await push()
            let stamp = now()
            settings.setLastSyncedAt(stamp)
            lastSyncedAt = stamp
            lastFailure = nil
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    private func pull() async throws {
        for change in try await transport.pull(since: lastSyncedAt) {
            guard change.deviceID != deviceID,
                  let remote = try? library.openSyncPayload(change.sealedRecording)
            else { continue }

            try library.applyRemote(remote)
        }
    }

    private func push() async throws {
        let changes = try library.recordings.map { recording in
            SyncChange(
                recordingID: recording.id,
                updatedAt: recording.updatedAt,
                deviceID: deviceID,
                sealedRecording: try library.sealForSync(recording)
            )
        }

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
