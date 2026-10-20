import CryptoKit
import Foundation
import Testing
@testable import Still

struct CallEndDetectorTests {
    private let start = Date(timeIntervalSince1970: 0)

    @Test
    func aRecordingStopsOnceTheCallItOverlappedIsOver() {
        var detector = CallEndDetector(quietPeriod: 30)

        #expect(!stops(&detector, [teams(microphone: true)], isRecording: true, at: start))
        #expect(!stops(&detector, [still], isRecording: true, at: start.addingTimeInterval(29)))
        #expect(stops(&detector, [still], isRecording: true, at: start.addingTimeInterval(30)))
        #expect(!stops(&detector, [still], isRecording: true, at: start.addingTimeInterval(60)))
    }

    @Test
    func aMutedCallKeepsTheRecordingGoing() {
        var detector = CallEndDetector(quietPeriod: 30)

        for second in stride(from: 0, through: 600, by: 3) {
            #expect(!stops(&detector, [teams(microphone: true), still], isRecording: true, at: start.addingTimeInterval(Double(second))))
        }
    }

    @Test
    func anInPersonRecordingIsNeverStoppedForLackOfACall() {
        var detector = CallEndDetector(quietPeriod: 30)

        for second in stride(from: 0, through: 600, by: 3) {
            #expect(!stops(&detector, [still], isRecording: true, at: start.addingTimeInterval(Double(second))))
        }
    }

    @Test
    func aBrowserMeetingCountsAsACall() {
        var detector = CallEndDetector(quietPeriod: 30)
        let chromeHelper = AudioProcessActivity(bundleID: "com.google.Chrome.helper", usesMicrophone: true, playsAudio: true)
        let safariAudio = AudioProcessActivity(bundleID: "com.apple.WebKit.GPU", usesMicrophone: true, playsAudio: false)

        #expect(!stops(&detector, [chromeHelper], isRecording: true, at: start))
        #expect(stops(&detector, [], isRecording: true, at: start.addingTimeInterval(30)))
        #expect(!stops(&detector, [safariAudio], isRecording: true, at: start.addingTimeInterval(40)))
        #expect(stops(&detector, [], isRecording: true, at: start.addingTimeInterval(70)))
    }

    @Test
    func aCallHeardBeforeTheRecordingDoesNotEndTheNextOne() {
        var detector = CallEndDetector(quietPeriod: 30)

        #expect(!stops(&detector, [teams(microphone: true)], isRecording: true, at: start))
        #expect(!stops(&detector, [], isRecording: false, at: start.addingTimeInterval(10)))
        #expect(!stops(&detector, [still], isRecording: true, at: start.addingTimeInterval(100)))
    }

    private func stops(_ detector: inout CallEndDetector, _ activity: [AudioProcessActivity], isRecording: Bool, at now: Date) -> Bool {
        detector.observe(activity, isRecording: isRecording, at: now)
    }

    private var still: AudioProcessActivity {
        AudioProcessActivity(bundleID: "com.andrii.still", usesMicrophone: true, playsAudio: false)
    }

    private func teams(microphone: Bool) -> AudioProcessActivity {
        AudioProcessActivity(bundleID: "com.microsoft.teams2", usesMicrophone: microphone, playsAudio: true)
    }
}

@MainActor
struct MicrophoneReleaseTests {
    @Test
    func theMicrophoneIsReleasedEvenWhenSystemAudioFailsToFinish() async throws {
        let microphone = SpyMicrophoneTrack()
        let recorder = MacAudioRecorder(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            cipher: LibraryCipher(key: SymmetricKey(size: .bits256)),
            microphone: microphone,
            systemAudio: FailingSystemAudioTrack(),
            capturesSystemAudio: { true },
            scope: { .callApps }
        )

        try await recorder.start(recordingID: UUID())
        try await recorder.finish()

        #expect(microphone.events == [.started, .finished])
        #expect(recorder.captureNote == CaptureError.systemAudioUnavailable.localizedDescription)
    }

    @Test
    func stoppingWhileTheLiveTranscriptStartsLeavesNothingListening() async {
        let session = GatedTranscriptionSession()
        let recorder = SpyAudioRecorder()
        let workflow = RecordingWorkflow(
            session: session,
            recorder: recorder,
            library: SpyRecordingLibrary(),
            showsLiveDraft: true,
            now: { Date(timeIntervalSince1970: 0) }
        )

        let starting = Task { await workflow.start() }
        while !session.isStarting { await Task.yield() }
        await workflow.save()
        session.release()
        await starting.value

        #expect(session.isRecording == false)
        #expect(workflow.state == .idle)
        #expect(recorder.events.contains(.discarded))
    }
}

@MainActor
private final class SpyMicrophoneTrack: MicrophoneTrack {
    enum Event: Equatable {
        case started
        case finished
        case discarded
    }

    private(set) var events: [Event] = []
    var captureNote: String? { nil }

    func start(recordingID: UUID) async throws {
        events.append(.started)
    }

    func finish() async throws {
        events.append(.finished)
    }

    func discard() async {
        events.append(.discarded)
    }
}

@MainActor
private final class FailingSystemAudioTrack: SystemAudioTrack {
    struct FinishFailed: Error {}

    func start(recordingID: UUID, startOffset: TimeInterval, scope: SystemAudioScope) async throws {}

    func finish() async throws {
        throw FinishFailed()
    }

    func discard() async {}
}

@MainActor
private final class GatedTranscriptionSession: TranscriptionSession {
    var transcript = ""
    private(set) var isRecording = false
    private(set) var isStarting = false
    var failure: String?
    private var continuation: CheckedContinuation<Void, Never>?

    func start() async throws {
        isStarting = true
        await withCheckedContinuation { continuation = $0 }
        isStarting = false
        isRecording = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func stop() {
        isRecording = false
    }
}
