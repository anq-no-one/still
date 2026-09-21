import Foundation

struct Recording: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var transcript: String
    let createdAt: Date
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        title: String,
        transcript: String,
        createdAt: Date = .now,
        duration: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.createdAt = createdAt
        self.duration = duration
    }
}
