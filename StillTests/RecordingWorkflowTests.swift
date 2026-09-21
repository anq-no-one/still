import Foundation
import Testing
@testable import Still

@MainActor
struct RecordingWorkflowTests {
    @Test
    func recordsAfterStart() async {
        let workflow = makeWorkflow()

        await workflow.start()

        #expect(workflow.state == .recording)
    }

    @Test
    func reportsCaptureFailure() async {
        let session = FakeTranscriptionSession()
        session.startError = TranscriptionError.speechPermissionDenied
        let workflow = makeWorkflow(session: session)

        await workflow.start()

        #expect(workflow.state == .failed(TranscriptionError.speechPermissionDenied.localizedDescription))
    }

    @Test
    func savesHeardSpeechIntoLibrary() async throws {
        let session = FakeTranscriptionSession()
        let library = SpyRecordingLibrary()
        let clock = StubClock(start: Date(timeIntervalSince1970: 1_000))
        let workflow = makeWorkflow(session: session, library: library, clock: clock)

        await workflow.start()
        session.transcript = " Ship the private beta on Friday "
        clock.advance(by: 90)
        workflow.save()

        #expect(workflow.state == .saved)
        #expect(library.recordings.count == 1)
        let recording = try #require(library.recordings.first)
        #expect(recording.transcript == "Ship the private beta on Friday")
        #expect(recording.title == "Ship the private beta on Friday")
        #expect(recording.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(recording.duration == 90)
        #expect(session.isRecording == false)
    }

    @Test
    func refusesToSaveSilence() async {
        let session = FakeTranscriptionSession()
        let library = SpyRecordingLibrary()
        let workflow = makeWorkflow(session: session, library: library)

        await workflow.start()
        session.transcript = "   "
        workflow.save()

        #expect(library.recordings.isEmpty)
        #expect(workflow.canSave == false)
        #expect(workflow.state == .failed(RecordingWorkflowError.emptyTranscript.localizedDescription))
    }

    @Test
    func refusesToRecordWithoutMicrophoneAccess() async {
        let recorder = SpyAudioRecorder()
        recorder.startError = CaptureError.microphonePermissionDenied
        let session = FakeTranscriptionSession()
        let workflow = makeWorkflow(session: session, recorder: recorder)

        await workflow.start()

        #expect(workflow.state == .failed(CaptureError.microphonePermissionDenied.localizedDescription))
        #expect(session.isRecording == false)
    }

    @Test
    func savedRecordingMatchesItsAudio() async throws {
        let session = FakeTranscriptionSession()
        let recorder = SpyAudioRecorder()
        let library = SpyRecordingLibrary()
        let workflow = makeWorkflow(session: session, recorder: recorder, library: library)

        await workflow.start()
        session.transcript = "Agreed the plan"
        workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(recorder.startedID == recording.id)
        #expect(recorder.events.last == .finished)
    }

    @Test
    func cancellingDiscardsCapturedAudio() async {
        let recorder = SpyAudioRecorder()
        let workflow = makeWorkflow(recorder: recorder)

        await workflow.start()
        workflow.cancel()

        #expect(recorder.events.last == .discarded)
    }

    @Test
    func cancellingKeepsLibraryUnchanged() async {
        let session = FakeTranscriptionSession()
        let library = SpyRecordingLibrary()
        let workflow = makeWorkflow(session: session, library: library)

        await workflow.start()
        session.transcript = "Discarded thought"
        workflow.cancel()

        #expect(library.recordings.isEmpty)
        #expect(session.isRecording == false)
        #expect(workflow.state == .idle)
    }

    @Test
    func elapsedFreezesAfterSaving() async {
        let session = FakeTranscriptionSession()
        let clock = StubClock(start: Date(timeIntervalSince1970: 0))
        let workflow = makeWorkflow(session: session, clock: clock)

        await workflow.start()
        session.transcript = "Recorded"
        clock.advance(by: 12)
        workflow.save()
        clock.advance(by: 300)

        #expect(workflow.elapsed == 12)
    }

    private func makeWorkflow(
        session: FakeTranscriptionSession = FakeTranscriptionSession(),
        recorder: SpyAudioRecorder = SpyAudioRecorder(),
        library: SpyRecordingLibrary = SpyRecordingLibrary(),
        clock: StubClock = StubClock(start: Date(timeIntervalSince1970: 0))
    ) -> RecordingWorkflow {
        RecordingWorkflow(session: session, recorder: recorder, library: library, now: clock.now)
    }
}

@MainActor
final class FakeTranscriptionSession: TranscriptionSession {
    var transcript = ""
    var isRecording = false
    var startError: Error?

    func start() async throws {
        if let startError { throw startError }
        isRecording = true
    }

    func stop() {
        isRecording = false
    }
}

@MainActor
final class SpyAudioRecorder: AudioRecorder {
    enum Event: Equatable {
        case started(UUID)
        case finished
        case discarded
    }

    var startError: Error?
    private(set) var events: [Event] = []

    var startedID: UUID? {
        events.compactMap { if case .started(let id) = $0 { return id } else { return nil } }.first
    }

    func start(recordingID: UUID) async throws {
        if let startError { throw startError }
        events.append(.started(recordingID))
    }

    func finish() throws {
        events.append(.finished)
    }

    func discard() {
        events.append(.discarded)
    }
}

@MainActor
final class SpyRecordingLibrary: RecordingLibrary {
    private(set) var recordings: [Recording] = []

    func add(_ recording: Recording) throws {
        recordings.append(recording)
    }
}

final class StubClock {
    private var current: Date

    init(start: Date) {
        current = start
    }

    func advance(by interval: TimeInterval) {
        current += interval
    }

    func now() -> Date {
        current
    }
}
