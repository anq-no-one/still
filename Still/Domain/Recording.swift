import Foundation

struct Recording: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var transcript: String
    var segments: [TranscriptSegment]
    let createdAt: Date
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        title: String,
        transcript: String,
        segments: [TranscriptSegment] = [],
        createdAt: Date = .now,
        duration: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.segments = segments
        self.createdAt = createdAt
        self.duration = duration
    }
}
