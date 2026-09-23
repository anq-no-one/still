import Foundation

struct Recording: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var transcript: String
    var segments: [TranscriptSegment]
    var speakers: [Speaker]
    var note: Note?
    let createdAt: Date
    let duration: TimeInterval
    var updatedAt: Date
    var deletedAt: Date?
    var projectID: UUID?
    var projectAssignedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        transcript: String,
        segments: [TranscriptSegment] = [],
        speakers: [Speaker] = [],
        note: Note? = nil,
        createdAt: Date = .now,
        duration: TimeInterval,
        updatedAt: Date = .now,
        deletedAt: Date? = nil,
        projectID: UUID? = nil,
        projectAssignedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.segments = segments
        self.speakers = speakers
        self.note = note
        self.createdAt = createdAt
        self.duration = duration
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.projectID = projectID
        self.projectAssignedAt = projectAssignedAt
    }

    var isDeleted: Bool {
        deletedAt != nil
    }
}
