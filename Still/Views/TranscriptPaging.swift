import Foundation

enum TranscriptPaging {
    static let initialSegmentBudget = 300
    static let pageSegmentBudget = 300

    struct Page: Equatable, Sendable {
        var blocks: [TranscriptBlock]
        var hasMore: Bool
    }

    static func visibleBlocks(_ blocks: [TranscriptBlock], segmentBudget: Int) -> Page {
        var kept: [TranscriptBlock] = []
        var used = 0
        for block in blocks {
            let remaining = segmentBudget - used
            if remaining <= 0 {
                return Page(blocks: kept, hasMore: true)
            }
            if block.segments.count <= remaining {
                kept.append(block)
                used += block.segments.count
            } else {
                kept.append(
                    TranscriptBlock(
                        speakerID: block.speakerID,
                        segments: Array(block.segments.prefix(remaining))
                    )!
                )
                return Page(blocks: kept, hasMore: true)
            }
        }
        return Page(blocks: kept, hasMore: false)
    }

    static func budgetCovering(_ blocks: [TranscriptBlock], startAt: TimeInterval?) -> Int? {
        guard let startAt else { return nil }
        var used = 0
        for block in blocks {
            used += block.segments.count
            if block.segments.contains(where: { $0.start >= startAt }) {
                return max(initialSegmentBudget, used)
            }
        }
        return nil
    }
}
