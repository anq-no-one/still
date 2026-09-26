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
}

struct Note: Codable, Equatable, Sendable {
    var template: NoteTemplate
    var summary: [NoteItem]
    var decisions: [NoteItem]
    var actions: [NoteItem]
    /// Text the user wrote. Regenerating the note never touches it.
    var userText: String

    init(
        template: NoteTemplate,
        summary: [NoteItem] = [],
        decisions: [NoteItem] = [],
        actions: [NoteItem] = [],
        userText: String = ""
    ) {
        self.template = template
        self.summary = summary
        self.decisions = decisions
        self.actions = actions
        self.userText = userText
    }

    var generatedItems: [NoteItem] {
        summary + decisions + actions
    }

    var isEmpty: Bool {
        generatedItems.isEmpty && userText.isEmpty
    }
}

enum NoteSchema {
    /// A Note is valid only when every generated claim points at transcript
    /// segments that exist. Anything else is ungrounded and gets rejected.
    static func isGrounded(_ note: Note, in segments: [TranscriptSegment]) -> Bool {
        let known = Set(segments.map(\.id))

        return note.generatedItems.allSatisfy { item in
            !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !item.sourceSegmentIDs.isEmpty
                && item.sourceSegmentIDs.allSatisfy(known.contains)
        }
    }
}
