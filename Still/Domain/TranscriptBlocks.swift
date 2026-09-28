import Foundation

struct TranscriptChunk: Identifiable, Equatable, Sendable {
    var segments: [TranscriptSegment]

    var id: UUID {
        segments[0].id
    }
}

struct TranscriptBlock: Identifiable, Equatable, Sendable {
    static let headerRepeatInterval = 5

    let speakerID: UUID?
    var segments: [TranscriptSegment]

    var id: UUID {
        segments[0].id
    }

    var start: TimeInterval {
        segments[0].start
    }

    func chunks() -> [TranscriptChunk] {
        stride(from: 0, to: segments.count, by: Self.headerRepeatInterval).map { start in
            TranscriptChunk(segments: Array(segments[start..<min(start + Self.headerRepeatInterval, segments.count)]))
        }
    }
}

enum TranscriptBlocks {
    static func group(_ segments: [TranscriptSegment]) -> [TranscriptBlock] {
        segments.reduce(into: []) { blocks, segment in
            if let last = blocks.last, last.speakerID == segment.speakerID {
                blocks[blocks.count - 1].segments.append(segment)
            } else {
                blocks.append(TranscriptBlock(speakerID: segment.speakerID, segments: [segment]))
            }
        }
    }
}
