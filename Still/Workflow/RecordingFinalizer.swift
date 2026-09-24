import Foundation

@MainActor
struct RecordingFinalizer {
    struct Draft {
        var id: UUID
        var title: String?
        var createdAt: Date
        var duration: TimeInterval
        var participants: [String] = []
        var cues: [SpeakerCue] = []
        var suggestedProjectID: UUID?
        var requiresTranscript = false
    }

    let finalTranscription: FinalTranscription
    let speakerSeparation: SpeakerSeparation
    let noteBuilder: GroundedNoteBuilder
    let library: RecordingLibrary

    @discardableResult
    func finalize(
        _ draft: Draft,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Recording {
        let transcription = try await transcribeAndSeparateSpeakers(draft, progress: progress)
        let segments = transcription?.segments ?? []
        let transcript = segments.plainText
        guard !transcript.isEmpty || transcription == nil else {
            throw RecordingWorkflowError.emptyTranscript
        }

        let note = await noteBuilder.note(
            segments: segments,
            duration: draft.duration,
            tracks: library.tracks(forRecording: draft.id)
        )
        try Task.checkCancellation()

        let recording = Recording(
            id: draft.id,
            title: draft.title ?? RecordingTitle.from(transcript: transcript, date: draft.createdAt),
            transcript: transcript,
            segments: segments,
            speakers: transcription?.speakers ?? [],
            expectedParticipants: draft.participants.isEmpty ? nil : draft.participants,
            note: note,
            createdAt: draft.createdAt,
            duration: draft.duration,
            projectID: draft.suggestedProjectID
        )
        try library.add(recording)
        return recording
    }

    private func transcribeAndSeparateSpeakers(
        _ draft: Draft,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult? {
        let tracks = try library.capturedTracks(forRecording: draft.id)
        let transcription: TranscriptionResult
        do {
            transcription = try await finalTranscription.run(
                tracks: tracks,
                checkpoints: try library.checkpointStore(forRecording: draft.id),
                progress: progress
            )
        } catch is TranscriptionError where !draft.requiresTranscript {
            return nil
        }
        var naming = library.speakerNaming
        naming.participants = draft.participants
        let separated = await speakerSeparation.separate(transcription, tracks: tracks, naming: naming)
        return SpeakerCueMatcher.suggest(draft.cues, for: separated, ownerName: naming.ownerName)
    }
}
