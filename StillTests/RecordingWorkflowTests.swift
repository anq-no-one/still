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
        #expect(recording.transcript == "Transcribed after saving")
        #expect(workflow.state == .saved)
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
        await workflow.save()

        #expect(workflow.state == .saved)
        #expect(library.recordings.count == 1)
        let recording = try #require(library.recordings.first)
        #expect(recording.transcript == "Transcribed after saving")
        #expect(recording.title == "Transcribed after saving")
        #expect(recording.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(recording.duration == 90)
        #expect(session.isRecording == false)
    }

    @Test
    func refusesToSaveSilence() async {
        let session = FakeTranscriptionSession()
        let library = SpyRecordingLibrary()
        let offlineTranscriber = StubOfflineTranscriber()
        let workflow = makeWorkflow(session: session, library: library, offlineTranscriber: offlineTranscriber)

        await workflow.start()
        session.transcript = "   "
        offlineTranscriber.result = ""
        await workflow.save()

        #expect(library.recordings.isEmpty)
        #expect(workflow.state == .failed(RecordingWorkflowError.emptyTranscript.localizedDescription))
    }

    @Test
    func keepsTheRecordingWhenThisDeviceCannotTranscribe() async throws {
        let session = FakeTranscriptionSession()
        let offlineTranscriber = StubOfflineTranscriber()
        offlineTranscriber.error = TranscriptionError.modelNotInstalled
        let recorder = SpyAudioRecorder()
        let library = SpyRecordingLibrary()
        let workflow = makeWorkflow(
            session: session,
            recorder: recorder,
            library: library,
            offlineTranscriber: offlineTranscriber
        )

        await workflow.start()
        await workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(workflow.state == .saved)
        #expect(recording.transcript.isEmpty)
        #expect(recording.segments.isEmpty)
        #expect(recorder.events.last == .finished)
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
        await workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(recorder.startedID == recording.id)
        #expect(recorder.events.last == .finished)
    }

    @Test
    func aFailedRecognizerKeepsTheRecordingAndTranscribesTheAudio() async throws {
        let session = FakeTranscriptionSession()
        let offlineTranscriber = StubOfflineTranscriber()
        let library = SpyRecordingLibrary()
        let clock = StubClock(start: Date(timeIntervalSince1970: 0))
        let workflow = makeWorkflow(
            session: session,
            library: library,
            offlineTranscriber: offlineTranscriber,
            clock: clock
        )

        await workflow.start()
        session.transcript = "Partial dr"
        session.failure = "Speech recognition stopped."
        clock.advance(by: 30)

        #expect(workflow.state == .recording)
        #expect(workflow.draftFailure == "Speech recognition stopped.")
        #expect(workflow.canSave)

        await workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(recording.transcript == "Transcribed after saving")
        #expect(offlineTranscriber.calls == 1)
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
    func freeRecordingHidesTheDraftAndTranscribesAfterSaving() async throws {
        let session = FakeTranscriptionSession()
        let offlineTranscriber = StubOfflineTranscriber()
        let library = SpyRecordingLibrary()
        let clock = StubClock(start: Date(timeIntervalSince1970: 0))
        let workflow = makeWorkflow(
            session: session,
            library: library,
            offlineTranscriber: offlineTranscriber,
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
        #expect(offlineTranscriber.calls == 1)
        #expect(recording.transcript == "Transcribed after saving")
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
    func namesTheSpeakersAfterTheFinalTranscript() async throws {
        let library = SpyRecordingLibrary()
        library.speakerNaming = SpeakerNamingContext(ownerName: "Andrii D.")
        let clock = StubClock(start: Date(timeIntervalSince1970: 500))
        var askedAbout: Date?
        let workflow = RecordingWorkflow(
            session: FakeTranscriptionSession(),
            finalTranscription: FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600),
            speakerSeparation: SpeakerSeparation(diarizer: StubDiarizer(turns: [SpeakerTurn(speaker: 0, start: 0, end: 5)])),
            expectedParticipants: { date in
                askedAbout = date
                return ["Anna Kowalska", "Ben Olsen"]
            },
            recorder: SpyAudioRecorder(),
            library: library,
            showsLiveDraft: false,
            now: clock.now
        )

        await workflow.start()
        clock.advance(by: 10)
        await workflow.save()

        let recording = try #require(library.recordings.first)
        #expect(recording.speakers.map(\.name) == ["Andrii D."])
        #expect(recording.segments.allSatisfy { $0.speakerID == recording.speakers[0].id })
        #expect(askedAbout == Date(timeIntervalSince1970: 500))
        #expect(recording.expectedParticipants == ["Anna Kowalska", "Ben Olsen"])
    }

    private func makeWorkflow(
        session: FakeTranscriptionSession = FakeTranscriptionSession(),
        recorder: SpyAudioRecorder = SpyAudioRecorder(),
        library: SpyRecordingLibrary = SpyRecordingLibrary(),
        offlineTranscriber: StubOfflineTranscriber = StubOfflineTranscriber(),
        showsLiveDraft: Bool = true,
        clock: StubClock = StubClock(start: Date(timeIntervalSince1970: 0))
    ) -> RecordingWorkflow {
        RecordingWorkflow(
            session: session,
            finalTranscription: FinalTranscription(transcriber: offlineTranscriber, windowSeconds: 3_600),
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
