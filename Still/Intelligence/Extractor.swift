import Foundation

struct ExtractionSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speaker: String?

    static func segments(of recording: Recording) -> [ExtractionSegment] {
        let speakers = Dictionary(recording.speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return recording.segments.map { segment in
            ExtractionSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: segment.displayText,
                speaker: segment.speakerID.flatMap { speakers[$0] }
            )
        }
    }
}

struct ExtractionCandidate: Equatable, Sendable {
    let kind: MemoryKind
    let text: String
    let citedSegmentIDs: [UUID]
    var owner: String?
    var due: String?
}

protocol Extractor: Sendable {
    var id: String { get }
    func candidates(from segments: [ExtractionSegment], language: String?) async throws -> [ExtractionCandidate]
}

struct TranscriptSentence: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let segmentIDs: [UUID]
    let speaker: String?

    static let maximumSegments = 40

    static func sentences(in segments: [ExtractionSegment]) -> [TranscriptSentence] {
        var sentences: [TranscriptSentence] = []
        var pending: [ExtractionSegment] = []

        func close() {
            let text = pending.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = pending.first, !text.isEmpty {
                sentences.append(
                    TranscriptSentence(text: text, start: first.start, segmentIDs: pending.map(\.id), speaker: first.speaker)
                )
            }
            pending.removeAll()
        }

        for segment in segments {
            if let last = pending.last, last.speaker != segment.speaker {
                close()
            }
            pending.append(segment)
            if segment.text.last.map({ ".?!".contains($0) }) == true || pending.count >= maximumSegments {
                close()
            }
        }
        close()

        return sentences
    }
}

enum ExtractionWindows {
    static let characterBudget = 2_400

    static func windows(of segments: [ExtractionSegment], characterBudget: Int = characterBudget) -> [[ExtractionSegment]] {
        let byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var windows: [[ExtractionSegment]] = []
        var current: [ExtractionSegment] = []
        var size = 0

        for sentence in TranscriptSentence.sentences(in: segments) {
            if !current.isEmpty, size + sentence.text.count > characterBudget {
                windows.append(current)
                current.removeAll()
                size = 0
            }
            current += sentence.segmentIDs.compactMap { byID[$0] }
            size += sentence.text.count
        }
        if !current.isEmpty {
            windows.append(current)
        }
        return windows
    }
}
