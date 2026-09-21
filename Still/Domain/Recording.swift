import Foundation

struct Recording: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var transcript: String
    var segments: [TranscriptSegment]
    var note: Note?
    let createdAt: Date
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        title: String,
        transcript: String,
        segments: [TranscriptSegment] = [],
        note: Note? = nil,
        createdAt: Date = .now,
        duration: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.segments = segments
        self.note = note
        self.createdAt = createdAt
        self.duration = duration
    }
}
