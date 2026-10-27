import Foundation

enum NoteTemplate: String, Codable, CaseIterable, Sendable {
    case meeting
    case lecture
    case interview
    case personalNote

    var title: String {
        switch self {
        case .meeting: String(localized: "Meeting")
        case .lecture: String(localized: "Lecture")
        case .interview: String(localized: "Interview")
        case .personalNote: String(localized: "Voice note")
        }
    }
}

struct NoteItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var text: String
    var sourceSegmentIDs: [UUID]
    var isUserAuthored: Bool

    init(id: UUID = UUID(), text: String, sourceSegmentIDs: [UUID], isUserAuthored: Bool = false) {
        self.id = id
        self.text = text
        self.sourceSegmentIDs = sourceSegmentIDs
        self.isUserAuthored = isUserAuthored
    }

    func speakerNames(segments: [TranscriptSegment], speakers: [Speaker]) -> [String] {
        let cited = Set(sourceSegmentIDs)
        let names = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var ordered: [String] = []
        for segment in segments where cited.contains(segment.id) {
            guard let name = segment.speakerID.flatMap({ names[$0] }), !ordered.contains(name) else { continue }
            ordered.append(name)
        }
        return ordered
    }
}

struct NoteGeneration: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case model
        case extractive
        case mixed
    }

    var source: Source
    var problem: String?
}

struct Note: Codable, Equatable, Sendable {
    var template: NoteTemplate
    var summary: [NoteItem]
    var decisions: [NoteItem]
    var actions: [NoteItem]
    var userText: String
    var generation: NoteGeneration?

    init(
        template: NoteTemplate,
        summary: [NoteItem] = [],
        decisions: [NoteItem] = [],
        actions: [NoteItem] = [],
        userText: String = "",
        generation: NoteGeneration? = nil
    ) {
        self.template = template
        self.summary = summary
        self.decisions = decisions
        self.actions = actions
        self.userText = userText
        self.generation = generation
    }

    var generatedItems: [NoteItem] {
        summary + decisions + actions
    }

    var isEmpty: Bool {
        generatedItems.isEmpty && userText.isEmpty
    }
}

enum NoteSchema {
    static func isGrounded(_ note: Note, in segments: [TranscriptSegment]) -> Bool {
        let known = Set(segments.map(\.id))

        return note.generatedItems.allSatisfy { item in
            !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !item.sourceSegmentIDs.isEmpty
                && item.sourceSegmentIDs.allSatisfy(known.contains)
        }
    }
}
