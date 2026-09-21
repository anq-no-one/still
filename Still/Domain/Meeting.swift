import Foundation
import SwiftData

@Model
final class Meeting {
    var id: UUID
    var title: String
    var transcript: String
    var createdAt: Date
    var duration: TimeInterval

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

