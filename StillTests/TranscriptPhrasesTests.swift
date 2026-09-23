import Foundation
import Testing
@testable import Still

struct TranscriptPhrasesTests {
    @Test
    func endsAPhraseAtASentenceMark() {
        let segments = TranscriptPhrases.segments(from: [
            word("Good", 0.0), word("morning.", 0.4),
            word("Budget", 1.0), word("moves.", 1.4),
        ])

        #expect(segments.map(\.text) == ["Good morning.", "Budget moves."])
        #expect(segments.first?.start == 0.0)
        #expect(segments.first?.end == 0.7)
    }

    @Test
    func endsAPhraseAtALongPause() {
        let segments = TranscriptPhrases.segments(from: [
            word("before", 0.0), word("pause", 0.3),
            word("after", 3.0),
        ])

        #expect(segments.map(\.text) == ["before pause", "after"])
    }

    @Test
    func averagesWordConfidenceAcrossThePhrase() throws {
        let segments = TranscriptPhrases.segments(from: [
            word("sure", 0.0, confidence: 0.9),
            word("maybe.", 0.3, confidence: 0.3),
        ])

        let confidence = try #require(segments.first?.confidence)
        #expect(abs(confidence - 0.6) < 0.0001)
    }

    @Test
    func turnsInt16AudioIntoMonoFloats() {
        let pcm = [Int16.max, 0, Int16.min + 1].withUnsafeBufferPointer { Data(buffer: $0) }

        #expect(PCMSamples.floats(fromInt16: pcm, channels: 1) == [1, 0, -1])
    }

    private func word(_ text: String, _ start: TimeInterval, confidence: Double = 0.9) -> SpokenWord {
        SpokenWord(text: text, start: start, end: start + 0.3, confidence: confidence)
    }
}
