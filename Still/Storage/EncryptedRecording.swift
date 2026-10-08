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

struct RecordingContent: Encodable {
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
    var isProcessing = false
    var titleSource: TitleSource?
}

extension RecordingContent: Decodable {
    enum CodingKeys: String, CodingKey {
        case title
        case transcript
        case segments
        case speakers
        case expectedParticipants
        case note
        case updatedAt
        case deletedAt
        case archivedAt
        case projectID
        case projectAssignedAt
        case mixedMediaSpans
        case memory
        case importedFrom
        case isProcessing
        case titleSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        transcript = try container.decode(String.self, forKey: .transcript)
        segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        speakers = try container.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        expectedParticipants = try container.decodeIfPresent([String].self, forKey: .expectedParticipants)
        note = try container.decodeIfPresent(Note.self, forKey: .note)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        projectAssignedAt = try container.decodeIfPresent(Date.self, forKey: .projectAssignedAt)
        mixedMediaSpans = try container.decodeIfPresent([TimeSpan].self, forKey: .mixedMediaSpans)
        memory = try container.decodeIfPresent(RecordingMemory.self, forKey: .memory)
        importedFrom = try container.decodeIfPresent(ImportedFile.self, forKey: .importedFrom)
        isProcessing = try container.decodeIfPresent(Bool.self, forKey: .isProcessing) ?? false
        titleSource = try container.decodeIfPresent(TitleSource.self, forKey: .titleSource)
    }
}
