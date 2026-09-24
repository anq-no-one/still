import Foundation
import Testing
@testable import Still

struct CallDetectorTests {
    private let zoom = "us.zoom.xos"
    private let slack = "com.tinyspeck.slackmacgap"
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test
    func aCallStartsWhenTheAppHoldsTheMicrophoneAndPlaysSound() {
        var detector = CallDetector(releaseGrace: 5)

        let events = detector.observe([activity(zoom, microphone: true, output: true)], at: start)

        #expect(events == [.started(zoom)])
        #expect(detector.activeCalls == [zoom])
    }

    @Test
    func anAppThatOnlyPlaysSoundIsIgnored() {
        var detector = CallDetector(releaseGrace: 5)

        let music = detector.observe([activity("com.apple.Music", microphone: false, output: true)], at: start)
        let voiceMessage = detector.observe([activity(slack, microphone: false, output: true)], at: start + 2)

        #expect(music.isEmpty)
        #expect(voiceMessage.isEmpty)
        #expect(detector.activeCalls.isEmpty)
    }

    @Test
    func anAppThatOnlyListensIsIgnored() {
        var detector = CallDetector(releaseGrace: 5)

        let events = detector.observe([activity(zoom, microphone: true, output: false)], at: start)

        #expect(events.isEmpty)
    }

    @Test
    func anUnknownAppNeverStartsACall() {
        var detector = CallDetector(releaseGrace: 5)

        let events = detector.observe([activity("com.example.Recorder", microphone: true, output: true)], at: start)

        #expect(events.isEmpty)
    }

    @Test
    func helperProcessesAddUpToTheirApp() {
        var detector = CallDetector(releaseGrace: 5)

        let events = detector.observe(
            [
                activity(slack, microphone: true, output: false),
                activity("\(slack).helper", microphone: false, output: true),
            ],
            at: start
        )

        #expect(events == [.started(slack)])
    }

    @Test
    func theCallContinuesThroughSilence() {
        var detector = CallDetector(releaseGrace: 5)
        _ = detector.observe([activity(zoom, microphone: true, output: true)], at: start)

        let events = detector.observe([activity(zoom, microphone: true, output: false)], at: start + 60)

        #expect(events.isEmpty)
        #expect(detector.activeCalls == [zoom])
    }

    @Test
    func aShortMicrophoneGapInsideTheGracePeriodKeepsTheCall() {
        var detector = CallDetector(releaseGrace: 5)
        _ = detector.observe([activity(zoom, microphone: true, output: true)], at: start)

        let gap = detector.observe([], at: start + 4)
        let back = detector.observe([activity(zoom, microphone: true, output: true)], at: start + 5)

        #expect(gap.isEmpty)
        #expect(back.isEmpty)
        #expect(detector.activeCalls == [zoom])
    }

    @Test
    func theCallEndsOnceTheMicrophoneStaysReleasedForTheGracePeriod() {
        var detector = CallDetector(releaseGrace: 5)
        _ = detector.observe([activity(zoom, microphone: true, output: true)], at: start)

        let early = detector.observe([activity(zoom, microphone: false, output: true)], at: start + 3)
        let late = detector.observe([activity(zoom, microphone: false, output: true)], at: start + 5)

        #expect(early.isEmpty)
        #expect(late == [.ended(zoom)])
        #expect(detector.activeCalls.isEmpty)
    }

    @Test
    func aNewCallCanStartAfterTheLastOneEnded() {
        var detector = CallDetector(releaseGrace: 5)
        _ = detector.observe([activity(zoom, microphone: true, output: true)], at: start)
        _ = detector.observe([], at: start + 10)

        let events = detector.observe([activity(zoom, microphone: true, output: true)], at: start + 20)

        #expect(events == [.started(zoom)])
    }

    @Test
    func faceTimeCallsAreHeardThroughTheConferencingService() {
        var detector = CallDetector(releaseGrace: 5)

        let events = detector.observe([activity("com.apple.avconferenced", microphone: true, output: true)], at: start)

        #expect(events == [.started("com.apple.FaceTime")])
    }

    @Test
    func resettingForgetsOpenCalls() {
        var detector = CallDetector(releaseGrace: 5)
        _ = detector.observe([activity(zoom, microphone: true, output: true)], at: start)

        detector.reset()

        #expect(detector.observe([], at: start + 60).isEmpty)
    }

    private func activity(_ bundleID: String, microphone: Bool, output: Bool) -> AudioProcessActivity {
        AudioProcessActivity(bundleID: bundleID, usesMicrophone: microphone, playsAudio: output)
    }
}
