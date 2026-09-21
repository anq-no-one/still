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
    private let library: MeetingLibrary
    private let now: () -> Date

    private var startedAt: Date?
    private var finishedAt: Date?

    private(set) var state: State = .idle

    init(session: TranscriptionSession, library: MeetingLibrary, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.library = library
        self.now = now
    }

    var transcript: String {
        session.transcript
    }

    var isCapturing: Bool {
        state == .recording
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? now()).timeIntervalSince(startedAt)
    }

    var canSave: Bool {
        !finishedTranscript.isEmpty
    }

    func start() async {
        guard state == .idle || isFailed else { return }

        state = .preparing
        startedAt = now()
        finishedAt = nil

        do {
            try await session.start()
            state = .recording
        } catch {
            finishedAt = now()
            state = .failed(error.localizedDescription)
        }
    }

    func save() {
        guard state == .recording else { return }

        state = .finalizing
        stopCapture()

        let transcript = finishedTranscript
        guard !transcript.isEmpty else {
            state = .failed(RecordingWorkflowError.emptyTranscript.localizedDescription)
            return
        }

        let startedAt = startedAt ?? now()
        library.add(
            Meeting(
                title: MeetingTitle.from(transcript: transcript, date: startedAt),
                transcript: transcript,
                createdAt: startedAt,
                duration: elapsed
            )
        )
        state = .saved
    }

    func cancel() {
        guard state != .saved else { return }

        stopCapture()
        state = .idle
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var finishedTranscript: String {
        session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
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
