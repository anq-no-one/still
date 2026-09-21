import Foundation

protocol NoteGenerator: Sendable {
    func note(
        template: NoteTemplate,
        segments: [TranscriptSegment]
    ) async throws -> Note
}

/// The grounded floor Still always has. It quotes the transcript instead of
/// writing new sentences, so nothing it produces can be invented.
struct ExtractiveNoteGenerator: NoteGenerator, Sendable {
    static let decisionCues = ["decided", "decision", "we agreed", "agreed to", "let's go with", "settled on"]
    static let actionCues = ["i will", "we will", "i'll", "we'll", "action item", "follow up", "next step", "by friday", "by monday", "todo"]

    let summaryLimit: Int

    init(summaryLimit: Int = 5) {
        self.summaryLimit = summaryLimit
    }

    func note(template: NoteTemplate, segments: [TranscriptSegment]) async throws -> Note {
        Note(
            template: template,
            summary: summary(from: segments),
            decisions: items(from: segments, matching: Self.decisionCues),
            actions: items(from: segments, matching: Self.actionCues)
        )
    }

    private func summary(from segments: [TranscriptSegment]) -> [NoteItem] {
        let sentences = Self.sentences(in: segments)
        let longest = sentences
            .sorted { $0.text.count > $1.text.count }
            .prefix(summaryLimit)

        return longest
            .sorted { $0.start < $1.start }
            .map { NoteItem(text: $0.text, sourceSegmentIDs: $0.sourceIDs) }
    }

    private func items(from segments: [TranscriptSegment], matching cues: [String]) -> [NoteItem] {
        Self.sentences(in: segments)
            .filter { sentence in
                let lowered = sentence.text.lowercased()
                return cues.contains { lowered.contains($0) }
            }
            .map { NoteItem(text: $0.text, sourceSegmentIDs: $0.sourceIDs) }
    }

    /// Word-level recognizer output becomes sentences, so a quoted claim reads
    /// like language while still naming every segment it came from.
    static func sentences(in segments: [TranscriptSegment]) -> [(text: String, start: TimeInterval, sourceIDs: [UUID])] {
        var sentences: [(String, TimeInterval, [UUID])] = []
        var words: [String] = []
        var ids: [UUID] = []
        var start: TimeInterval = 0

        for segment in segments {
            if words.isEmpty { start = segment.start }
            words.append(segment.displayText)
            ids.append(segment.id)

            guard segment.displayText.last.map({ ".?!".contains($0) }) == true else { continue }

            sentences.append((words.joined(separator: " "), start, ids))
            words.removeAll()
            ids.removeAll()
        }

        if !words.isEmpty {
            sentences.append((words.joined(separator: " "), start, ids))
        }

        return sentences.map { (text: $0.0, start: $0.1, sourceIDs: $0.2) }
    }
}

/// Runs the preferred generator and keeps its result only when every claim is
/// grounded. Anything else falls back to the extractive note.
struct GroundedNoteBuilder: Sendable {
    let preferred: NoteGenerator?
    let fallback: ExtractiveNoteGenerator

    init(preferred: NoteGenerator? = nil, fallback: ExtractiveNoteGenerator = ExtractiveNoteGenerator()) {
        self.preferred = preferred
        self.fallback = fallback
    }

    func note(
        segments: [TranscriptSegment],
        duration: TimeInterval,
        tracks: [AudioTrack]
    ) async -> Note {
        let template = NoteTemplateSelector.template(segments: segments, duration: duration, tracks: tracks)

        if let preferred,
           let generated = try? await preferred.note(template: template, segments: segments),
           NoteSchema.isGrounded(generated, in: segments) {
            return generated
        }

        return (try? await fallback.note(template: template, segments: segments))
            ?? Note(template: template)
    }
}
