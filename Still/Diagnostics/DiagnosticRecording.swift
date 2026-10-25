import Foundation
import Synchronization

/// The recording being captured right now. Audio threads, device callbacks
/// and sync work cannot see the workflow's task-local context, so they read
/// it from here to file their records under the recording they belong to.
enum DiagnosticRecording {
    private static let current = Mutex<UUID?>(nil)

    static var id: UUID? {
        current.withLock { $0 }
    }

    static var fields: [String: String] {
        id.map { ["recordingID": $0.uuidString] } ?? [:]
    }

    static func began(_ id: UUID) {
        current.withLock { $0 = id }
    }

    static func ended(_ id: UUID) {
        current.withLock { if $0 == id { $0 = nil } }
    }
}
