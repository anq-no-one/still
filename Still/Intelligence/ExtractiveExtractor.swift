import Foundation

struct ExtractiveExtractor: Extractor {
    static let factCues = [
        "deadline", "budget", "costs", "price", "release", "launch", "the plan is", "is scheduled", "is due",
        "will ship", "ships on", "signed", "contract", "percent", "customers",
    ]
    static let ownCommitments = ["i will", "i'll", "i can", "let me"]
    static let dueWords = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "tomorrow", "today",
        "next week", "end of the week", "end of the month", "end of day",
    ]

    let id = "extractive"

    func candidates(from segments: [ExtractionSegment], language: String?) async throws -> [ExtractionCandidate] {
        TranscriptSentence.sentences(in: segments).compactMap { sentence in
            let lowered = sentence.text.lowercased()
            if Self.mentions(ExtractiveNoteGenerator.decisionCues, in: lowered),
               ExtractiveNoteGenerator.isSubstantive(sentence.text, cues: ExtractiveNoteGenerator.decisionCues) {
                return ExtractionCandidate(kind: .decision, text: sentence.text, citedSegmentIDs: sentence.segmentIDs)
            }
            if Self.mentions(ExtractiveNoteGenerator.actionCues, in: lowered),
               ExtractiveNoteGenerator.isSubstantive(sentence.text, cues: ExtractiveNoteGenerator.actionCues) {
                return ExtractionCandidate(
                    kind: .task,
                    text: sentence.text,
                    citedSegmentIDs: sentence.segmentIDs,
                    owner: Self.mentions(Self.ownCommitments, in: lowered) ? sentence.speaker : nil,
                    due: Self.dueWords.first { lowered.contains($0) }
                )
            }
            if Self.mentions(Self.factCues, in: lowered) || sentence.text.contains(where: \.isNumber) {
                return ExtractionCandidate(kind: .fact, text: sentence.text, citedSegmentIDs: sentence.segmentIDs)
            }
            return nil
        }
    }

    private static func mentions(_ cues: [String], in lowered: String) -> Bool {
        cues.contains { lowered.contains($0) }
    }
}
