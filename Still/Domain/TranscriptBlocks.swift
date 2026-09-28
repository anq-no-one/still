import Foundation

struct TranscriptChunk: Identifiable, Equatable, Sendable {
    let segments: [TranscriptSegment]

    init?(segments: [TranscriptSegment]) {
        guard !segments.isEmpty else { return nil }
        self.segments = segments
    }

    var id: UUID {
        segments[0].id
    }
}

struct TranscriptBlock: Identifiable, Equatable, Sendable {
    static let headerRepeatInterval = 5

    let speakerID: UUID?
    private(set) var segments: [TranscriptSegment]

    init?(speakerID: UUID?, segments: [TranscriptSegment]) {
        guard !segments.isEmpty else { return nil }
        self.speakerID = speakerID
        self.segments = segments
    }

    var id: UUID {
        segments[0].id
    }

    var start: TimeInterval {
        segments[0].start
    }

    mutating func append(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    func chunks() -> [TranscriptChunk] {
        stride(from: 0, to: segments.count, by: Self.headerRepeatInterval).compactMap { start in
            TranscriptChunk(segments: Array(segments[start..<min(start + Self.headerRepeatInterval, segments.count)]))
        }
    }
}

enum TranscriptBlocks {
    static func group(_ segments: [TranscriptSegment]) -> [TranscriptBlock] {
        segments.reduce(into: []) { blocks, segment in
            if let last = blocks.last, last.speakerID == segment.speakerID {
                blocks[blocks.count - 1].append(segment)
            } else if let block = TranscriptBlock(speakerID: segment.speakerID, segments: [segment]) {
                blocks.append(block)
            }
        }
    }
}
