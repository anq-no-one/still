import Foundation

struct MeetingParticipant: Equatable, Sendable {
    let id: UUID
    let name: String
    let isYou: Bool
}

struct MeetingSegment: Equatable, Sendable {
    let id: UUID
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let speakerID: UUID?
    let speaker: String?
    let text: String
    let language: String?
}

struct MeetingNoteItem: Equatable, Sendable {
    let id: UUID
    let text: String
    let timeSeconds: TimeInterval?
    let sourceSegmentIDs: [UUID]
    let isUserAuthored: Bool
}

struct MeetingMemoryItem: Equatable, Sendable {
    let id: String
    let kind: MemoryKind
    let text: String
    let timeSeconds: TimeInterval
    let sourceSegmentIDs: [UUID]
    let verification: String
    let owner: String?
    let due: String?

    init?(_ item: MemoryItem) {
        switch item.status {
        case .extracted: verification = "automatically_extracted"
        case .confirmed: verification = "user_confirmed"
        case .accepted: verification = "user_accepted"
        case .proposed, .rejected, .dismissed: return nil
        }
        id = item.id
        kind = item.kind
        text = item.text
        timeSeconds = item.sourceStart
        sourceSegmentIDs = item.sourceSegmentIDs
        owner = item.owner
        due = item.due
    }
}

struct MeetingNotes: Equatable, Sendable {
    let kind: String
    let summary: [MeetingNoteItem]
    let decisions: [MeetingNoteItem]
    let actionItems: [MeetingNoteItem]
    let userNotes: String
}

struct MeetingRecord: Equatable, Sendable {
    let id: UUID
    let title: String
    let startedAt: Date
    let durationSeconds: TimeInterval
    let updatedAt: Date
    let participants: [MeetingParticipant]
    let transcript: String
    let segments: [MeetingSegment]
    let notes: MeetingNotes?
    var memory: [MeetingMemoryItem] = []
}

struct MeetingSearchHit: Equatable, Sendable {
    let meetingID: UUID
    let match: String
    let snippet: String
    let timeSeconds: TimeInterval?
    let segmentID: UUID?
}

enum MeetingSourceError: Error, Equatable {
    case locked
}

@MainActor
protocol MeetingSource: AnyObject {
    func meetings() throws -> [MeetingRecord]
    func search(_ query: String) throws -> [MeetingSearchHit]
    func markdown(forMeeting id: UUID) throws -> String?
}

@MainActor
final class LibraryMeetingSource: MeetingSource {
    private let library: Library

    init(library: Library) {
        self.library = library
    }

    func meetings() throws -> [MeetingRecord] {
        guard library.state == .unlocked else { throw MeetingSourceError.locked }
        return library.recordings.map(MeetingRecord.init)
    }

    func search(_ query: String) throws -> [MeetingSearchHit] {
        guard library.state == .unlocked else { throw MeetingSourceError.locked }
        return LibrarySearch.results(for: query, in: library.recordings).map(MeetingSearchHit.init)
    }

    func markdown(forMeeting id: UUID) throws -> String? {
        guard library.state == .unlocked else { throw MeetingSourceError.locked }
        return library.recordings.first { $0.id == id }.map(RecordingDocument.markdown)
    }
}

extension MeetingRecord {
    init(_ recording: Recording) {
        let names = Dictionary(recording.speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let starts = Dictionary(recording.segments.map { ($0.id, $0.start) }, uniquingKeysWith: { first, _ in first })

        func item(_ item: NoteItem) -> MeetingNoteItem {
            MeetingNoteItem(
                id: item.id,
                text: item.text,
                timeSeconds: item.sourceSegmentIDs.first.flatMap { starts[$0] },
                sourceSegmentIDs: item.sourceSegmentIDs,
                isUserAuthored: item.isUserAuthored
            )
        }

        self.init(
            id: recording.id,
            title: recording.title,
            startedAt: recording.createdAt,
            durationSeconds: recording.duration,
            updatedAt: recording.updatedAt,
            participants: recording.speakers.map { MeetingParticipant(id: $0.id, name: $0.name, isYou: $0.isYou) },
            transcript: recording.transcript,
            segments: recording.segments.map { segment in
                MeetingSegment(
                    id: segment.id,
                    startSeconds: segment.start,
                    endSeconds: segment.end,
                    speakerID: segment.speakerID,
                    speaker: segment.speakerID.flatMap { names[$0] },
                    text: segment.displayText,
                    language: segment.language
                )
            },
            notes: recording.note.map { note in
                MeetingNotes(
                    kind: note.template.rawValue,
                    summary: note.summary.map(item),
                    decisions: note.decisions.map(item),
                    actionItems: note.actions.map(item),
                    userNotes: note.userText
                )
            },
            memory: (recording.memory?.items ?? []).compactMap(MeetingMemoryItem.init)
        )
    }
}

extension MeetingSearchHit {
    init(_ result: SearchResult) {
        let match = switch result.match {
        case .title: "title"
        case .transcript: "transcript"
        case .note: "note"
        }
        self.init(
            meetingID: result.recordingID,
            match: match,
            snippet: result.snippet,
            timeSeconds: result.time,
            segmentID: result.segmentID
        )
    }
}
