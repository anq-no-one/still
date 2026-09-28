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
    func aRecognizerThatWillNotStartCostsTheDraftNotTheRecording() async throws {
        let session = FakeTranscriptionSession()
        session.startError = TranscriptionError.recognitionFailed
        let recorder = SpyAudioRecorder()
        let library = SpyRecordingLibrary()
        let clock = StubClock(start: Date(timeIntervalSince1970: 0))
        let workflow = makeWorkflow(session: session, recorder: recorder, library: library, clock: clock)

        await workflow.start()

        #expect(workflow.state == .recording)
        #expect(workflow.draftFailure == TranscriptionError.recognitionFailed.localizedDescription)
        #expect(!recorder.events.contains(.discarded))

        clock.advance(by: 20)
        await workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(recording.transcript.isEmpty)
        #expect(recording.isProcessing)
        #expect(workflow.state == .saved)
    }

    @Test
    func filesAPlaceholderImmediatelySoTheLibraryListsItWhileItRenders() async throws {
        let session = FakeTranscriptionSession()
        let library = SpyRecordingLibrary()
        let clock = StubClock(start: Date(timeIntervalSince1970: 1_000))
        let workflow = makeWorkflow(session: session, library: library, clock: clock)

        await workflow.start()
        session.transcript = " Ship the private beta on Friday "
        clock.advance(by: 90)
        await workflow.save()

        #expect(workflow.state == .saved)
        #expect(library.recordings.count == 1)
        let recording = try #require(library.recordings.first)
        #expect(recording.transcript == " Ship the private beta on Friday ")
        #expect(recording.title == "Ship the private beta on Friday")
        #expect(recording.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(recording.duration == 90)
        #expect(recording.isProcessing)
        #expect(session.isRecording == false)
    }

    @Test
    func savesSilenceAsAProcessingPlaceholderForTheBackgroundPassToJudge() async throws {
        let session = FakeTranscriptionSession()
        let library = SpyRecordingLibrary()
        let workflow = makeWorkflow(session: session, library: library)

        await workflow.start()
        session.transcript = "   "
        await workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(workflow.state == .saved)
        #expect(recording.isProcessing)
        #expect(recording.transcript == "   ")
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
    func savedPlaceholderMatchesItsAudio() async throws {
        let session = FakeTranscriptionSession()
        let recorder = SpyAudioRecorder()
        let library = SpyRecordingLibrary()
        let workflow = makeWorkflow(session: session, recorder: recorder, library: library)

        await workflow.start()
        session.transcript = "Agreed the plan"
        await workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(recorder.startedID == recording.id)
        #expect(recorder.events.last == .finished)
    }

    @Test
    func aFailedRecognizerKeepsItsPartialDraftInThePlaceholder() async throws {
        let session = FakeTranscriptionSession()
        let library = SpyRecordingLibrary()
        let clock = StubClock(start: Date(timeIntervalSince1970: 0))
        let workflow = makeWorkflow(session: session, library: library, clock: clock)

        await workflow.start()
        session.transcript = "Partial dr"
        session.failure = "Speech recognition stopped."
        clock.advance(by: 30)

        #expect(workflow.state == .recording)
        #expect(workflow.draftFailure == "Speech recognition stopped.")
        #expect(workflow.canSave)

        await workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(recording.transcript == "Partial dr")
        #expect(recording.isProcessing)
    }

    @Test
    func cancellingDiscardsCapturedAudio() async {
        let recorder = SpyAudioRecorder()
        let workflow = makeWorkflow(recorder: recorder)

        await workflow.start()
        await workflow.cancel()

        #expect(recorder.events.last == .discarded)
    }

    @Test
    func freeRecordingHidesTheDraftAndFilesAnUntitledPlaceholder() async throws {
        let session = FakeTranscriptionSession()
        let library = SpyRecordingLibrary()
        let clock = StubClock(start: Date(timeIntervalSince1970: 0))
        let workflow = makeWorkflow(
            session: session,
            library: library,
            showsLiveDraft: false,
            clock: clock
        )

        await workflow.start()

        #expect(workflow.showsDraft == false)
        #expect(workflow.transcript.isEmpty)
        #expect(session.isRecording == false)

        clock.advance(by: 20)

        #expect(workflow.canSave)

        await workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(recording.transcript.isEmpty)
        #expect(recording.isProcessing)
    }

    @Test
    func cancellingKeepsLibraryUnchanged() async {
        let session = FakeTranscriptionSession()
        let library = SpyRecordingLibrary()
        let workflow = makeWorkflow(session: session, library: library)

        await workflow.start()
        session.transcript = "Discarded thought"
        await workflow.cancel()

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
        await workflow.save()
        clock.advance(by: 300)

        #expect(workflow.elapsed == 12)
    }

    @Test
    func handsTheCoordinatorEverythingTheBackgroundPassNeeds() async throws {
        let session = FakeTranscriptionSession()
        let clock = StubClock(start: Date(timeIntervalSince1970: 500))
        let workflow = makeWorkflow(session: session, clock: clock)

        await workflow.start()
        session.transcript = "Planning the launch"
        workflow.speakerStarted("Anna Kowalska")
        clock.advance(by: 10)
        workflow.speakerEnded("Anna Kowalska")
        await workflow.save()

        let draft = try #require(workflow.pendingFinalization)
        #expect(draft.id == workflow.recordingID)
        #expect(draft.createdAt == Date(timeIntervalSince1970: 500))
        #expect(draft.duration == 10)
        #expect(draft.cues.count == 1)
        #expect(draft.cues.first?.name == "Anna Kowalska")
    }

    private func makeWorkflow(
        session: FakeTranscriptionSession = FakeTranscriptionSession(),
        recorder: SpyAudioRecorder = SpyAudioRecorder(),
        library: SpyRecordingLibrary = SpyRecordingLibrary(),
        showsLiveDraft: Bool = true,
        clock: StubClock = StubClock(start: Date(timeIntervalSince1970: 0))
    ) -> RecordingWorkflow {
        RecordingWorkflow(
            session: session,
            recorder: recorder,
            library: library,
            showsLiveDraft: showsLiveDraft,
            now: clock.now
        )
    }
}

@MainActor
final class FakeTranscriptionSession: TranscriptionSession {
    var transcript = ""
    var isRecording = false
    var failure: String?
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

    func finish() async throws {
        events.append(.finished)
    }

    func discard() async {
        events.append(.discarded)
    }
}

@MainActor
final class SpyRecordingLibrary: RecordingLibrary {
    private(set) var recordings: [Recording] = []
    var capturedPCM = Data(repeating: 3, count: 32_000)
    var capturedTrack = AudioTrack.microphone

    func add(_ recording: Recording) throws {
        recordings.append(recording)
    }

    func capturedTracks(forRecording id: UUID) throws -> [CapturedTrack] {
        [CapturedTrack(track: capturedTrack, format: .transcription, startOffset: 0, pcm: capturedPCM)]
    }

    func checkpointStore(forRecording id: UUID) throws -> TranscriptionCheckpointStore {
        MemoryCheckpointStore()
    }

    func tracks(forRecording id: UUID) -> [AudioTrack] {
        [capturedTrack]
    }

    var speakerNaming = SpeakerNamingContext.none
    var vocabularies: [UUID: ProjectVocabulary] = [:]

    func vocabulary(forProject id: UUID?) -> ProjectVocabulary {
        guard let id else { return ProjectVocabulary(projectID: UUID()) }
        return vocabularies[id] ?? ProjectVocabulary(projectID: id)
    }
}

final class StubOfflineTranscriber: OfflineTranscriber, @unchecked Sendable {
    var result = "Transcribed after saving"
    var error: Error?
    private(set) var calls = 0

    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment] {
        calls += 1
        if let error { throw error }
        guard !result.isEmpty else { return [] }
        return [TranscriptSegment(start: 0, end: 5, text: result, language: "en", confidence: 0.9)]
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
