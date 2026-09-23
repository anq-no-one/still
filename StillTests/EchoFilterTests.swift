import Foundation
import Testing
@testable import Still

struct EchoFilterTests {
    private let you = Speaker.forTrack(.microphone)
    private let others = Speaker.forTrack(.system)

    @Test
    func dropsTheMicrophoneHearingTheCallThroughTheSpeakers() {
        let segments = [
            segment("Let's ship in English first.", 10, 12, others),
            segment("let's ship in English first", 10.3, 12.4, you),
        ]

        let kept = EchoFilter.removingEcho(from: segments, speakers: [you, others])

        #expect(kept.map(\.text) == ["Let's ship in English first."])
    }

    @Test
    func keepsWhatYouSayOverTheOtherSide() {
        let segments = [
            segment("One risk is the translation work.", 20, 23, others),
            segment("Sorry, which document?", 21, 22, you),
        ]

        let kept = EchoFilter.removingEcho(from: segments, speakers: [you, others])

        #expect(kept.count == 2)
    }

    @Test
    func keepsTheSameWordsSaidAtAnotherTime() {
        let segments = [
            segment("Ship it on Friday.", 5, 6, others),
            segment("Ship it on Friday.", 40, 41, you),
        ]

        #expect(EchoFilter.removingEcho(from: segments, speakers: [you, others]).count == 2)
    }

    @Test
    func leavesAMicrophoneOnlyRecordingUntouched() {
        let segments = [segment("Just me talking.", 0, 2, you)]

        #expect(EchoFilter.removingEcho(from: segments, speakers: [you]) == segments)
    }

    private func segment(_ text: String, _ start: TimeInterval, _ end: TimeInterval, _ speaker: Speaker) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, language: "en", confidence: 0.9, speakerID: speaker.id)
    }
}
