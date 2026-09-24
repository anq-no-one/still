import Foundation
import Testing
@testable import Still

struct MixedMediaLogTests {
    @Test
    func pairsEachStartWithItsEndAndClosesAnOpenSpan() {
        var log = MixedMediaLog()
        log.began(at: 10)
        log.began(at: 12)
        log.ended(at: 20)
        log.ended(at: 25)
        log.began(at: 40)

        #expect(log.spans(closingAt: 50) == [TimeSpan(start: 10, end: 20), TimeSpan(start: 40, end: 50)])
    }

    @Test
    func marksOnlySegmentsThatOverlapASpan() {
        let span = TimeSpan(start: 10, end: 20)
        let inside = TranscriptSegment(start: 15, end: 18, text: "a", language: "en", confidence: 1)
        let before = TranscriptSegment(start: 2, end: 10, text: "b", language: "en", confidence: 1)

        #expect(span.overlaps(inside))
        #expect(!span.overlaps(before))
    }
}
