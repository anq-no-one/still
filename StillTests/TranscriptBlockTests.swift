import Foundation
import Testing
@testable import Still

struct TranscriptBlockTests {
    @Test
    func consecutiveLinesFromOneSpeakerShareABlock() {
        let speaker = UUID()
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "Hello", language: "en", confidence: 0.9, speakerID: speaker),
            TranscriptSegment(start: 2, end: 4, text: "Welcome", language: "en", confidence: 0.9, speakerID: speaker),
        ]

        let blocks = TranscriptBlocks.group(segments)

        #expect(blocks.count == 1)
        #expect(blocks[0].speakerID == speaker)
        #expect(blocks[0].segments.map(\.id) == segments.map(\.id))
        #expect(blocks[0].start == 0)
    }

    @Test
    func aNewSpeakerStartsANewBlockAndAReturningOneToo() {
        let first = UUID()
        let second = UUID()
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "Hello", language: "en", confidence: 0.9, speakerID: first),
            TranscriptSegment(start: 2, end: 4, text: "Hi", language: "en", confidence: 0.9, speakerID: second),
            TranscriptSegment(start: 4, end: 6, text: "Again", language: "en", confidence: 0.9, speakerID: first),
        ]

        let blocks = TranscriptBlocks.group(segments)

        #expect(blocks.map(\.speakerID) == [first, second, first])
        #expect(blocks.map { $0.segments.count } == [1, 1, 1])
    }

    @Test
    func linesWithoutASpeakerGroupTogether() {
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "Hello", language: "en", confidence: 0.9),
            TranscriptSegment(start: 2, end: 4, text: "World", language: "en", confidence: 0.9),
        ]

        let blocks = TranscriptBlocks.group(segments)

        #expect(blocks.count == 1)
        #expect(blocks[0].speakerID == nil)
    }

    @Test
    func aLongBlockRepeatsItsHeaderEveryFifthLine() {
        let speaker = UUID()
        let segments = (0..<12).map { index in
            TranscriptSegment(
                start: TimeInterval(index * 2),
                end: TimeInterval(index * 2 + 2),
                text: "Line \(index)",
                language: "en",
                confidence: 0.9,
                speakerID: speaker
            )
        }

        let chunks = TranscriptBlocks.group(segments)[0].chunks()

        #expect(chunks.map { $0.segments.count } == [5, 5, 2])
        #expect(chunks.flatMap(\.segments).map(\.id) == segments.map(\.id))
    }

    @Test
    func groupingKeepsEverySegmentIDStable() {
        let segments = (0..<4).map { index in
            TranscriptSegment(
                start: TimeInterval(index * 2),
                end: TimeInterval(index * 2 + 2),
                text: "Line \(index)",
                language: "en",
                confidence: 0.9,
                speakerID: index.isMultiple(of: 2) ? UUID() : nil
            )
        }

        let blocks = TranscriptBlocks.group(segments)

        #expect(blocks.flatMap(\.segments).map(\.id) == segments.map(\.id))
    }
}
