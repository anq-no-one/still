import Foundation
import Testing
@testable import Still

struct WindowBoundaryVocabularyTests {
    private let format = AudioFormat(sampleRate: 1_000, channels: 1, bitsPerSample: 16)

    private func vocabulary(term: String, variants: [String]) -> ProjectVocabulary {
        var vocabulary = ProjectVocabulary(projectID: UUID())
        vocabulary.upsert(VocabularyTerm(term: term, variants: variants))
        return vocabulary
    }

    private func segment(_ text: String, start: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 1, text: text, language: "en", confidence: 0.9)
    }

    @Test
    func aTermSplitAcrossTwoWindowsIsJoined() {
        let vocabulary = vocabulary(term: "Choke Set", variants: ["choke set"])
        let segments = [
            segment("We adjusted the choke", start: 274),
            segment("set to forty percent.", start: 275),
        ]

        let corrected = VocabularyCorrector.apply(vocabulary, to: segments)

        #expect(corrected[0].displayText == "We adjusted the Choke Set")
        #expect(corrected[1].displayText == "to forty percent.")
        #expect(corrected[0].start == 274)
        #expect(corrected[1].start == 275)
    }

    @Test
    func aBoundaryJoinNeedsEveryWordOfTheTerm() {
        let vocabulary = vocabulary(term: "Choke Set", variants: ["choke set"])
        let segments = [
            segment("We adjusted the valve", start: 274),
            segment("set to forty percent.", start: 275),
        ]

        #expect(VocabularyCorrector.apply(vocabulary, to: segments) == segments)
    }

    @Test
    func aBoundaryJoinNeverTouchesAlreadyCorrectedSegments() {
        let vocabulary = vocabulary(term: "Choke Set", variants: ["choke set", "choke"])
        let segments = [
            segment("We adjusted the choke", start: 274),
            segment("set to forty percent.", start: 275),
        ]

        let corrected = VocabularyCorrector.apply(vocabulary, to: segments)

        #expect(corrected[0].displayText == "We adjusted the Choke Set")
        #expect(corrected[1].displayText == "set to forty percent.")
        #expect(corrected.filter(\.isCorrected).count == 1)
    }

    @Test
    func windowOffsetsHoldAtFourThirtyFive() async throws {
        let transcriber = WindowTranscriber()
        let final = FinalTranscription(transcriber: transcriber, windowSeconds: 10)
        let pcm = Data(repeating: 9, count: 10 * format.bytesPerSecond)

        let result = try await final.run(
            tracks: [CapturedTrack(track: .microphone, format: format, startOffset: 275, pcm: pcm)],
            checkpoints: MemoryCheckpointStore()
        )

        #expect(result.segments.map(\.start) == [275])
    }
}
