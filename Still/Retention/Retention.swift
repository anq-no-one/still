import Foundation

enum RetentionPolicy: String, Codable, CaseIterable, Sendable {
    case forever
    case days30
    case days90
    case days365

    var title: String {
        switch self {
        case .forever: String(localized: "Keep audio until I delete it")
        case .days30: String(localized: "Delete audio after 30 days")
        case .days90: String(localized: "Delete audio after 90 days")
        case .days365: String(localized: "Delete audio after a year")
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .forever: nil
        case .days30: 30 * 86_400
        case .days90: 90 * 86_400
        case .days365: 365 * 86_400
        }
    }
}

struct RetentionSweep: Equatable, Sendable {
    var audioToDelete: [UUID] = []
    var recordingsToPurge: [UUID] = []
    var orphanAudio: [UUID] = []

    var isEmpty: Bool {
        audioToDelete.isEmpty && recordingsToPurge.isEmpty && orphanAudio.isEmpty
    }
}

enum Retention {
    /// A deleted Recording stays restorable for this long before its ciphertext
    /// is removed for good. Other devices see the same window, so a deletion
    /// that syncs late still lands on the same decision.
    static let recoveryWindow: TimeInterval = 30 * 86_400

    static func sweep(
        recordings: [Recording],
        policy: RetentionPolicy,
        audioDirectories: [UUID],
        now: Date
    ) -> RetentionSweep {
        var sweep = RetentionSweep()
        let known = Set(recordings.map(\.id))
        let withAudio = Set(audioDirectories)

        for recording in recordings {
            if let deletedAt = recording.deletedAt {
                if now.timeIntervalSince(deletedAt) >= recoveryWindow {
                    sweep.recordingsToPurge.append(recording.id)
                }
                continue
            }

            guard let seconds = policy.seconds,
                  withAudio.contains(recording.id),
                  now.timeIntervalSince(recording.createdAt) >= seconds
            else { continue }

            sweep.audioToDelete.append(recording.id)
        }

        // Audio with no Recording left to describe it cannot be restored into
        // anything, so it goes rather than waiting to be resurrected.
        sweep.orphanAudio = audioDirectories.filter { !known.contains($0) }

        return sweep
    }
}
