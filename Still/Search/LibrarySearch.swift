import Foundation

struct SearchResult: Identifiable, Equatable, Sendable {
    enum Match: Equatable, Sendable {
        case title
        case transcript
        case note
    }

    let id: UUID
    let recordingID: UUID
    let segmentID: UUID?
    let time: TimeInterval?
    let match: Match
    let snippet: String

    init(
        id: UUID = UUID(),
        recordingID: UUID,
        segmentID: UUID? = nil,
        time: TimeInterval? = nil,
        match: Match,
        snippet: String
    ) {
        self.id = id
        self.recordingID = recordingID
        self.segmentID = segmentID
        self.time = time
        self.match = match
        self.snippet = snippet
    }
}

/// Searches the unlocked Library in memory. The index is derived from the
/// decrypted recordings and rebuilt on every unlock, so deleting a recording
/// removes it from results and nothing derived has to be kept in sync.
enum LibrarySearch {
    static let defaultSemanticThreshold: Float = 0.6

    /// Exact matches rank first because a word the user actually typed is the
    /// strongest signal available. Semantic hits fill the gaps below them,
    /// standing in for a result exact search would have missed entirely.
    static func results(
        for query: String,
        in recordings: [Recording],
        semanticIndex: SemanticIndex? = nil,
        semanticThreshold: Float = defaultSemanticThreshold
    ) -> [SearchResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count > 1 else { return [] }

        let exact = recordings.flatMap { recording in
            titleResults(needle, in: recording)
                + segmentResults(needle, in: recording)
                + noteResults(needle, in: recording)
        }

        guard let semanticIndex else { return exact }

        let known = Set(recordings.map(\.id))
        let alreadyMatched = Set(exact.map { SegmentKey(recordingID: $0.recordingID, segmentID: $0.segmentID) })

        let semantic = semanticIndex.matches(for: needle, threshold: semanticThreshold)
            .filter { known.contains($0.recordingID) }
            .filter { !alreadyMatched.contains(SegmentKey(recordingID: $0.recordingID, segmentID: $0.segmentID)) }
            .sorted { $0.score > $1.score }
            .map { match in
                SearchResult(
                    recordingID: match.recordingID,
                    segmentID: match.segmentID,
                    time: match.time,
                    match: .transcript,
                    snippet: match.text
                )
            }

        return exact + semantic
    }

    private struct SegmentKey: Hashable {
        let recordingID: UUID
        let segmentID: UUID?
    }

    private static func titleResults(_ needle: String, in recording: Recording) -> [SearchResult] {
        guard contains(recording.title, needle) else { return [] }

        return [
            SearchResult(
                recordingID: recording.id,
                time: 0,
                match: .title,
                snippet: recording.title
            )
        ]
    }

    private static func segmentResults(_ needle: String, in recording: Recording) -> [SearchResult] {
        guard !recording.segments.isEmpty else {
            return contains(recording.transcript, needle)
                ? [SearchResult(recordingID: recording.id, time: 0, match: .transcript, snippet: recording.transcript)]
                : []
        }

        return ExtractiveNoteGenerator.sentences(in: recording.segments)
            .filter { contains($0.text, needle) }
            .map { sentence in
                SearchResult(
                    recordingID: recording.id,
                    segmentID: sentence.sourceIDs.first,
                    time: sentence.start,
                    match: .transcript,
                    snippet: sentence.text
                )
            }
    }

    private static func noteResults(_ needle: String, in recording: Recording) -> [SearchResult] {
        guard let note = recording.note else { return [] }

        let items = note.generatedItems.filter { contains($0.text, needle) }.map { item in
            SearchResult(
                recordingID: recording.id,
                segmentID: item.sourceSegmentIDs.first,
                time: time(of: item.sourceSegmentIDs.first, in: recording),
                match: .note,
                snippet: item.text
            )
        }

        guard contains(note.userText, needle) else { return items }

        return items + [
            SearchResult(recordingID: recording.id, match: .note, snippet: note.userText)
        ]
    }

    private static func time(of segmentID: UUID?, in recording: Recording) -> TimeInterval? {
        guard let segmentID else { return nil }
        return recording.segments.first { $0.id == segmentID }?.start
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
