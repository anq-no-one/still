import Foundation
import SwiftData

@Model
final class EncryptedRecording {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var sealedContent: Data

    init(id: UUID, createdAt: Date, duration: TimeInterval, sealedContent: Data) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.sealedContent = sealedContent
    }
}

struct RecordingContent: Codable {
    var title: String
    var transcript: String
    var segments: [TranscriptSegment] = []
    var speakers: [Speaker] = []
    var note: Note?
}
