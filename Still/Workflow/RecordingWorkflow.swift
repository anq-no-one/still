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
    private let finalTranscription: FinalTranscription
    private let recorder: AudioRecorder
    private let library: RecordingLibrary
    private let showsLiveDraft: Bool
    private let now: () -> Date

    private var recordingID = UUID()
    private var startedAt: Date?
    private var finishedAt: Date?

    private(set) var state: State = .idle

    init(
        session: TranscriptionSession,
        finalTranscription: FinalTranscription,
        recorder: AudioRecorder,
        library: RecordingLibrary,
        showsLiveDraft: Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.finalTranscription = finalTranscription
        self.recorder = recorder
        self.library = library
        self.showsLiveDraft = showsLiveDraft
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
        showsLiveDraft ? session.failure : nil
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
            state = .recording
        } catch {
            await recorder.discard()
            fail(with: error)
        }
    }

    func save() async {
        guard state == .recording else { return }

        state = .finalizing
        stopCapture()

        do {
            try await recorder.finish()
            let segments = try await finalSegments()
            let transcript = segments.plainText
            guard !transcript.isEmpty else {
                await recorder.discard()
                state = .failed(RecordingWorkflowError.emptyTranscript.localizedDescription)
                return
            }

            let startedAt = startedAt ?? now()
            try library.add(
                Recording(
                    id: recordingID,
                    title: RecordingTitle.from(transcript: transcript, date: startedAt),
                    transcript: transcript,
                    segments: segments,
                    createdAt: startedAt,
                    duration: elapsed
                )
            )
            state = .saved
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() async {
        guard state != .saved else { return }

        stopCapture()
        await recorder.discard()
        state = .idle
    }

    /// The live draft is a preview. The saved transcript always comes from the
    /// journaled audio, so it carries timings and survives a failed recognizer.
    private func finalSegments() async throws -> [TranscriptSegment] {
        let captured = try library.capturedAudio(forRecording: recordingID)
        return try await finalTranscription.run(
            pcm: captured.pcm,
            format: captured.format,
            checkpoints: try library.checkpointStore(forRecording: recordingID)
        )
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var draftTranscript: String {
        session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
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
