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
    var expectedParticipants: [String]?
    var note: Note?
    var updatedAt: Date?
    var deletedAt: Date?
    var archivedAt: Date?
    var projectID: UUID?
    var projectAssignedAt: Date?
    var mixedMediaSpans: [TimeSpan]?
    var memory: RecordingMemory?
    var importedFrom: ImportedFile?
}
