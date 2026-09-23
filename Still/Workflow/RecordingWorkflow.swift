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
    private let speakerSeparation: SpeakerSeparation
    private let expectedParticipants: @MainActor (Date) async -> [String]
    private let noteBuilder: GroundedNoteBuilder
    private let recorder: AudioRecorder
    private let library: RecordingLibrary
    private let showsLiveDraft: Bool
    private let now: () -> Date

    private var recordingID = UUID()
    private var startedAt: Date?
    private var finishedAt: Date?
    private var draftStartFailure: String?

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
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.finalTranscription = finalTranscription
        self.speakerSeparation = speakerSeparation
        self.expectedParticipants = expectedParticipants
        self.noteBuilder = noteBuilder
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

    func save() async {
        guard state == .recording else { return }

        state = .finalizing
        stopCapture()

        do {
            try await recorder.finish()
            let participants = await expectedParticipants(startedAt ?? now())
            let transcription = try await transcribeAndSeparateSpeakers(expecting: participants)
            let segments = transcription?.segments ?? []
            let transcript = segments.plainText
            guard !transcript.isEmpty || transcription == nil else {
                await recorder.discard()
                state = .failed(RecordingWorkflowError.emptyTranscript.localizedDescription)
                return
            }

            let note = await noteBuilder.note(
                segments: segments,
                duration: elapsed,
                tracks: library.tracks(forRecording: recordingID)
            )

            let startedAt = startedAt ?? now()
            try library.add(
                Recording(
                    id: recordingID,
                    title: RecordingTitle.from(transcript: transcript, date: startedAt),
                    transcript: transcript,
                    segments: segments,
                    speakers: transcription?.speakers ?? [],
                    expectedParticipants: participants.isEmpty ? nil : participants,
                    note: note,
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

    private func transcribeAndSeparateSpeakers(expecting participants: [String]) async throws -> TranscriptionResult? {
        let tracks = try library.capturedTracks(forRecording: recordingID)
        let transcription: TranscriptionResult
        do {
            transcription = try await finalTranscription.run(
                tracks: tracks,
                checkpoints: try library.checkpointStore(forRecording: recordingID)
            )
        } catch is TranscriptionError {
            return nil
        }
        var naming = library.speakerNaming
        naming.participants = participants
        return await speakerSeparation.separate(transcription, tracks: tracks, naming: naming)
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
