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
    private let offlineTranscriber: OfflineTranscriber
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
        offlineTranscriber: OfflineTranscriber,
        recorder: AudioRecorder,
        library: RecordingLibrary,
        showsLiveDraft: Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.offlineTranscriber = offlineTranscriber
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

    var isCapturing: Bool {
        state == .recording
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? now()).timeIntervalSince(startedAt)
    }

    var canSave: Bool {
        guard state == .recording else { return false }
        return showsLiveDraft ? !draftTranscript.isEmpty : elapsed > 0
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
            recorder.discard()
            fail(with: error)
        }
    }

    func save() async {
        guard state == .recording else { return }

        state = .finalizing
        stopCapture()

        do {
            try recorder.finish()
            let transcript = try await resolvedTranscript()
            guard !transcript.isEmpty else {
                recorder.discard()
                state = .failed(RecordingWorkflowError.emptyTranscript.localizedDescription)
                return
            }

            let startedAt = startedAt ?? now()
            try library.add(
                Recording(
                    id: recordingID,
                    title: RecordingTitle.from(transcript: transcript, date: startedAt),
                    transcript: transcript,
                    createdAt: startedAt,
                    duration: elapsed
                )
            )
            state = .saved
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        guard state != .saved else { return }

        stopCapture()
        recorder.discard()
        state = .idle
    }

    private func resolvedTranscript() async throws -> String {
        if showsLiveDraft { return draftTranscript }

        let captured = try library.capturedAudio(forRecording: recordingID)
        return try await offlineTranscriber
            .transcript(of: captured.pcm, format: captured.format)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
