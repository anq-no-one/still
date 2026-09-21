import Foundation

/// What a device sends. The payload is already sealed, so a transport only ever
/// handles ciphertext plus the metadata it needs to order changes.
struct SyncChange: Equatable, Sendable {
    let recordingID: UUID
    let updatedAt: Date
    let deviceID: UUID
    let sealedRecording: Data
}

protocol SyncTransport: Sendable {
    func push(_ changes: [SyncChange]) async throws
    func pull(since: Date?) async throws -> [SyncChange]
}

enum SyncError: LocalizedError, Equatable {
    case disabled
    case unreachable

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Sync is off. Nothing has left this device."
        case .unreachable:
            "Still could not reach iCloud. Your recordings are unchanged and it will try again."
        }
    }
}
