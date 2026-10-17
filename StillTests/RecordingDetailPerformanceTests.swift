import Foundation
import Testing
@testable import Still

/// Switching recordings must stay instant no matter how long the transcript
/// is. Paging caps the rows built on selection; the rest loads on demand.
struct TranscriptPagingTests {
    @Test
    func shortTranscriptsRenderWhole() {
        let blocks = blocks(speakers: 2, segmentsPerSpeaker: 3)

        let page = TranscriptPaging.visibleBlocks(blocks, segmentBudget: 300)

        #expect(page.blocks.count == 2)
        #expect(!page.hasMore)
    }

    @Test
    func longMonologuesTruncateMidBlockWithMoreToShow() {
        let blocks = blocks(speakers: 1, segmentsPerSpeaker: 500)

        let page = TranscriptPaging.visibleBlocks(blocks, segmentBudget: 300)

        #expect(page.blocks.count == 1)
        #expect(page.blocks[0].segments.count == 300)
        #expect(page.hasMore)
    }

    @Test
    func growingTheBudgetShowsMoreRows() {
        let blocks = blocks(speakers: 1, segmentsPerSpeaker: 500)

        let grown = TranscriptPaging.visibleBlocks(
            blocks,
            segmentBudget: 300 + TranscriptPaging.pageSegmentBudget
        )

        #expect(grown.blocks[0].segments.count == 500)
        #expect(!grown.hasMore)
    }

    @Test
    func budgetCoversASearchHitBeyondTheFirstPage() {
        let blocks = blocks(speakers: 4, segmentsPerSpeaker: 200)
        let target = blocks[3].segments[10].start

        let covering = TranscriptPaging.budgetCovering(blocks, startAt: target)

        #expect(covering == 800)
    }

    @Test
    func noStartTimeNeedsNoExtraBudget() {
        let blocks = blocks(speakers: 4, segmentsPerSpeaker: 200)

        #expect(TranscriptPaging.budgetCovering(blocks, startAt: nil) == nil)
    }

    private func blocks(speakers: Int, segmentsPerSpeaker: Int) -> [TranscriptBlock] {
        (0..<speakers).compactMap { speaker in
            let segments = (0..<segmentsPerSpeaker).map { index in
                TranscriptSegment(
                    start: TimeInterval(speaker * 1_000 + index),
                    end: TimeInterval(speaker * 1_000 + index) + 1,
                    text: "Sentence number \(index) .",
                    language: "en",
                    confidence: 0.9
                )
            }
            return TranscriptBlock(speakerID: UUID(), segments: segments)
        }
    }
}
