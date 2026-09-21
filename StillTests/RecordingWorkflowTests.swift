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
        let library = SpyMeetingLibrary()
        let clock = StubClock(start: Date(timeIntervalSince1970: 1_000))
        let workflow = makeWorkflow(session: session, library: library, clock: clock)

        await workflow.start()
        session.transcript = " Ship the private beta on Friday "
        clock.advance(by: 90)
        workflow.save()

        #expect(workflow.state == .saved)
        #expect(library.meetings.count == 1)
        let meeting = try #require(library.meetings.first)
        #expect(meeting.transcript == "Ship the private beta on Friday")
        #expect(meeting.title == "Ship the private beta on Friday")
        #expect(meeting.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(meeting.duration == 90)
        #expect(session.isRecording == false)
    }

    @Test
    func refusesToSaveSilence() async {
        let session = FakeTranscriptionSession()
        let library = SpyMeetingLibrary()
        let workflow = makeWorkflow(session: session, library: library)

        await workflow.start()
        session.transcript = "   "
        workflow.save()

        #expect(library.meetings.isEmpty)
        #expect(workflow.canSave == false)
        #expect(workflow.state == .failed(RecordingWorkflowError.emptyTranscript.localizedDescription))
    }

    @Test
    func cancellingKeepsLibraryUnchanged() async {
        let session = FakeTranscriptionSession()
        let library = SpyMeetingLibrary()
        let workflow = makeWorkflow(session: session, library: library)

        await workflow.start()
        session.transcript = "Discarded thought"
        workflow.cancel()

        #expect(library.meetings.isEmpty)
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
        library: SpyMeetingLibrary = SpyMeetingLibrary(),
        clock: StubClock = StubClock(start: Date(timeIntervalSince1970: 0))
    ) -> RecordingWorkflow {
        RecordingWorkflow(session: session, library: library, now: clock.now)
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
final class SpyMeetingLibrary: MeetingLibrary {
    private(set) var meetings: [Meeting] = []

    func add(_ meeting: Meeting) {
        meetings.append(meeting)
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
