import Foundation
import Observation

@MainActor
@Observable
final class RecordingWorkflow {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case finalizing
        case saved
        case failed(String)
    }

    private let session: TranscriptionSession
    private let finalizer: RecordingFinalizer
    private let expectedParticipants: @MainActor (Date) async -> [String]
    private let recorder: AudioRecorder
    private let showsLiveDraft: Bool
    private let suggestedProjectID: UUID?
    private let now: () -> Date

    private(set) var recordingID = UUID()
    private var startedAt: Date?
    private var finishedAt: Date?
    private var draftStartFailure: String?
    private var speakerCues = SpeakerCueLog()
    private var mixedMedia = MixedMediaLog()

    private(set) var state: State = .idle

    init(
        session: TranscriptionSession,
        finalTranscription: FinalTranscription,
        speakerSeparation: SpeakerSeparation = .trackBased,
        expectedParticipants: @escaping @MainActor (Date) async -> [String] = { _ in [] },
        noteBuilder: GroundedNoteBuilder = GroundedNoteBuilder(),
        recorder: AudioRecorder,
        library: RecordingLibrary,
        showsLiveDraft: Bool,
        suggestedProjectID: UUID? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.finalizer = RecordingFinalizer(
            finalTranscription: finalTranscription,
            speakerSeparation: speakerSeparation,
            noteBuilder: noteBuilder,
            library: library
        )
        self.expectedParticipants = expectedParticipants
        self.recorder = recorder
        self.showsLiveDraft = showsLiveDraft
        self.suggestedProjectID = suggestedProjectID
        self.now = now
    }

    var transcript: String {
        showsLiveDraft ? session.transcript : ""
    }

    var showsDraft: Bool {
        showsLiveDraft
    }

    /// A recognizer that dies mid-recording does not end the recording. Capture
    /// keeps journaling audio and the transcript comes from the saved audio.
    var draftFailure: String? {
        guard showsLiveDraft else { return nil }
        return draftStartFailure ?? session.failure
    }

    var captureNote: String? {
        recorder.captureNote
    }

    var isCapturing: Bool {
        state == .recording
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? now()).timeIntervalSince(startedAt)
    }

    var canSave: Bool {
        state == .recording && elapsed > 0
    }

    func start() async {
        guard state == .idle || isFailed else { return }

        state = .preparing
        recordingID = UUID()
        startedAt = now()
        finishedAt = nil
        draftStartFailure = nil
        speakerCues = SpeakerCueLog()
        mixedMedia = MixedMediaLog()

        do {
            try await recorder.start(recordingID: recordingID)
        } catch {
            fail(with: error)
            return
        }

        guard showsLiveDraft else {
            state = .recording
            return
        }

        do {
            try await session.start()
        } catch {
            // The audio is the part worth keeping. A recognizer that will not
            // start costs the live preview, not the recording.
            draftStartFailure = error.localizedDescription
        }

        state = .recording
    }

    func speakerStarted(_ name: String) {
        guard let offset = recordingOffset else { return }
        speakerCues.began(name, at: offset)
    }

    func speakerEnded(_ name: String) {
        guard let offset = recordingOffset else { return }
        speakerCues.ended(name, at: offset)
    }

    func otherMediaStarted() {
        guard let offset = recordingOffset else { return }
        mixedMedia.began(at: offset)
    }

    func otherMediaEnded() {
        guard let offset = recordingOffset else { return }
        mixedMedia.ended(at: offset)
    }

    func save() async {
        guard state == .recording else { return }

        state = .finalizing
        stopCapture()
        let cues = speakerCues.cues(closingAt: elapsed)
        speakerCues = SpeakerCueLog()
        let mixed = mixedMedia.spans(closingAt: elapsed)
        mixedMedia = MixedMediaLog()

        do {
            try await recorder.finish()
            let startedAt = startedAt ?? now()
            try await finalizer.finalize(
                RecordingFinalizer.Draft(
                    id: recordingID,
                    createdAt: startedAt,
                    duration: elapsed,
                    participants: await expectedParticipants(startedAt),
                    cues: cues,
                    mixedMedia: mixed,
                    suggestedProjectID: suggestedProjectID
                )
            )
            state = .saved
        } catch RecordingWorkflowError.emptyTranscript {
            await recorder.discard()
            state = .failed(RecordingWorkflowError.emptyTranscript.localizedDescription)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() async {
        guard state != .saved else { return }

        stopCapture()
        speakerCues = SpeakerCueLog()
        mixedMedia = MixedMediaLog()
        await recorder.discard()
        state = .idle
    }

    private var recordingOffset: TimeInterval? {
        guard state == .recording, let startedAt else { return nil }
        return now().timeIntervalSince(startedAt)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func fail(with error: Error) {
        finishedAt = now()
        state = .failed(error.localizedDescription)
    }

    private func stopCapture() {
        session.stop()
        if finishedAt == nil {
            finishedAt = now()
        }
    }
}

enum RecordingWorkflowError: LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "Still did not hear any speech to save."
        }
    }
}
