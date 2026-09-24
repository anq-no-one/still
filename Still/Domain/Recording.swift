import Foundation

struct Recording: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var transcript: String
    var segments: [TranscriptSegment]
    var speakers: [Speaker]
    var expectedParticipants: [String]?
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
        expectedParticipants: [String]? = nil,
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
        self.expectedParticipants = expectedParticipants
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

    var unclaimedParticipants: [String] {
        var taken = Set(speakers.map { VoiceProfiles.key(for: $0.name) })
        return (expectedParticipants ?? []).filter { taken.insert(VoiceProfiles.key(for: $0)).inserted }
    }

    func renamingSpeaker(_ speaker: Speaker, to name: String) -> Recording {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = speakers.firstIndex(where: { $0.id == speaker.id }) else { return self }

        var renamed = self
        renamed.speakers[index] = speakers[index].named(trimmed, by: .user)
        return renamed
    }
}
