import Foundation

struct SyncChange: Equatable, Sendable {
    enum Kind: String, Sendable {
        case recording
        case project
        case vocabulary
        case device
        case trust
        case grant
    }

    let id: UUID
    var kind: Kind = .recording
    let updatedAt: Date
    let deviceID: UUID
    var scopeID: UUID?
    var recipientID: UUID?
    var payload: Data?

    var isWithdrawnGrant: Bool {
        kind == .grant && payload?.isEmpty == true
    }
}

protocol SyncTransport: Sendable {
    func push(_ changes: [SyncChange]) async throws
    func pull(payloadsFor scopes: Set<UUID>) async throws -> [SyncChange]
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
