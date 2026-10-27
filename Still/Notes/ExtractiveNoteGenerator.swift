import Foundation

protocol NoteGenerator: Sendable {
    func note(
        template: NoteTemplate,
        segments: [TranscriptSegment],
        speakers: [Speaker]
    ) async throws -> Note
}

extension NoteGenerator {
    func note(template: NoteTemplate, segments: [TranscriptSegment]) async throws -> Note {
        try await note(template: template, segments: segments, speakers: [])
    }
}

struct ExtractiveNoteGenerator: NoteGenerator, Sendable {
    static let decisionCues = ["decided", "decision", "we agreed", "agreed to", "let's go with", "settled on"]
    static let actionCues = ["i will", "we will", "i'll", "we'll", "action item", "follow up", "next step", "by friday", "by monday", "todo"]

    let summaryLimit: Int

    init(summaryLimit: Int = 5) {
        self.summaryLimit = summaryLimit
    }

    func note(template: NoteTemplate, segments: [TranscriptSegment], speakers _: [Speaker]) async throws -> Note {
        Note(
            template: template,
            summary: summary(from: segments),
            decisions: items(from: segments, matching: Self.decisionCues),
            actions: items(from: segments, matching: Self.actionCues),
            generation: NoteGeneration(source: .extractive)
        )
    }

    private func summary(from segments: [TranscriptSegment]) -> [NoteItem] {
        let sentences = Self.sentences(in: segments)
        let ranked = sentences.enumerated().sorted { lhs, rhs in
            let left = Self.importance(of: lhs.element.text)
            let right = Self.importance(of: rhs.element.text)
            return left == right ? lhs.offset < rhs.offset : left > right
        }
        var seen: Set<String> = []
        let selected = ranked.filter { seen.insert(MemoryText.normalized($0.element.text)).inserted }
            .prefix(summaryLimit)
            .sorted { $0.offset < $1.offset }
        return selected.map { NoteItem(text: $0.element.text, sourceSegmentIDs: $0.element.sourceIDs) }
    }

    static func importance(of text: String) -> Int {
        if isDecision(text) { return 100 }
        if isAction(text) { return 80 }
        let lowered = normalized(text)
        if isAvailability(text) { return 40 }
        if ExtractiveExtractor.factCues.contains(where: lowered.contains) || text.contains(where: \.isNumber) { return 50 }
        if text.contains("?") { return 0 }
        return min(MemoryText.words(in: text).count, 20)
    }

    private func items(from segments: [TranscriptSegment], matching cues: [String]) -> [NoteItem] {
        Self.sentences(in: segments)
            .filter { cues == Self.decisionCues ? Self.isDecision($0.text) : Self.isAction($0.text) }
            .map { NoteItem(text: $0.text, sourceSegmentIDs: $0.sourceIDs) }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    static func isAvailability(_ text: String) -> Bool {
        let lowered = normalized(text)
        return ["pto", "on leave", "on vacation", "on holiday", "out of office", "unavailable", "not available", "away tomorrow"].contains { lowered.contains($0) }
    }

    static func isDecision(_ text: String) -> Bool {
        let lowered = normalized(text)
        guard !lowered.contains("?"),
              !["not decided", "haven't decided", "haven't agreed", "not agreed", "if we agreed", "no decision"].contains(where: lowered.contains)
        else { return false }
        return decisionCues.contains(where: lowered.contains) && isSubstantive(text, cues: decisionCues)
    }

    static func isAction(_ text: String) -> Bool {
        let lowered = normalized(text)
        guard !isAvailability(text), !lowered.contains("?"),
              !["will be able", "we'll be able", "i'll be able", "will have been", "will already", "will not", "won't", "would", "might", "could"].contains(where: lowered.contains)
        else { return false }
        let commitment = lowered.range(of: #"\b(?:[\p{L}]+ will|i'll|we'll|i am going to|i'm going to|we are going to|we're going to)\b"#, options: .regularExpression)
        guard let commitment else { return false }
        let remainder = String(lowered[commitment.upperBound...])
        let terms = MemoryText.words(in: remainder)
        let verbs: Set<String> = ["send", "share", "write", "prepare", "review", "test", "fix", "check", "update", "deploy", "implement", "confirm", "organize", "organise", "install", "investigate", "report", "contact", "book", "reschedule", "deliver", "complete", "cancel", "enable", "disable", "reproduce", "run", "chase", "ping", "find", "create", "publish", "merge", "release", "upload", "schedule", "follow"]
        guard terms.contains(where: verbs.contains) else { return false }
        let vague: Set<String> = ["i", "we", "you", "it", "that", "this", "them", "those", "something", "somebody", "someone", "again", "still", "just", "then", "now", "tomorrow", "today", "the", "a", "an", "to", "for", "of", "on", "in", "by", "and", "with", "go", "have", "do", "out", "up", "back", "please"]
        return terms.filter { !vague.contains($0) && !verbs.contains($0) }.contains { $0.count > 2 }
    }

    static func isSubstantive(_ sentence: String, cues: [String]) -> Bool {
        var remainder = sentence.lowercased()
        for cue in cues {
            remainder = remainder.replacingOccurrences(of: cue, with: " ")
        }
        let words = remainder.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.filter { $0.count > 1 }.count >= 3
    }

    static func sentences(in segments: [TranscriptSegment]) -> [(text: String, start: TimeInterval, sourceIDs: [UUID])] {
        var sentences: [(String, TimeInterval, [UUID])] = []
        var words: [String] = []
        var ids: [UUID] = []
        var start: TimeInterval = 0
        var speaker: UUID?

        for segment in segments {
            let cleaned = DisfluencyFilter.cleanedDisplayText(of: segment)
            guard !cleaned.isEmpty else { continue }
            if !words.isEmpty, segment.speakerID != speaker {
                sentences.append((words.joined(separator: " "), start, ids))
                words.removeAll()
                ids.removeAll()
            }
            if words.isEmpty {
                start = segment.start
                speaker = segment.speakerID
            }
            words.append(cleaned)
            ids.append(segment.id)

            guard cleaned.last.map({ ".?!".contains($0) }) == true else { continue }

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

struct GroundedNoteBuilder: Sendable {
    let preferred: NoteGenerator?
    let fallback: ExtractiveNoteGenerator

    init(preferred: NoteGenerator? = nil, fallback: ExtractiveNoteGenerator = ExtractiveNoteGenerator()) {
        self.preferred = preferred
        self.fallback = fallback
    }

    func note(
        segments: [TranscriptSegment],
        speakers: [Speaker] = [],
        duration: TimeInterval,
        tracks: [AudioTrack]
    ) async -> Note {
        let template = NoteTemplateSelector.template(segments: segments, duration: duration, tracks: tracks)

        var problem: String?
        if let preferred {
            do {
                var generated = try await preferred.note(template: template, segments: segments, speakers: speakers)
                if NoteSchema.isGrounded(generated, in: segments) {
                    if generated.generation == nil { generated.generation = NoteGeneration(source: .model) }
                    AITrace.record("note.chosen", ["source": generated.generation?.source.rawValue ?? "model", "template": String(describing: template), "note": AITrace.json(generated)])
                    return generated
                }
                problem = "notGrounded"
                AITrace.record("note.rejected", ["reason": "notGrounded", "note": AITrace.json(generated)])
            } catch {
                problem = String(describing: error)
                AITrace.record("note.rejected", ["reason": String(describing: error)])
            }
        }

        var note = (try? await fallback.note(template: template, segments: segments))
            ?? Note(template: template)
        note.generation = NoteGeneration(source: .extractive, problem: problem)
        AITrace.record("note.chosen", [
            "source": preferred == nil ? "extractive (no model)" : "extractive fallback",
            "template": String(describing: template),
            "note": AITrace.json(note),
        ])
        return note
    }
}
