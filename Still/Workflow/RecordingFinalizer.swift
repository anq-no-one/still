import Foundation

@MainActor
struct RecordingFinalizer {
    struct Draft {
        var id: UUID
        var title: String?
        var createdAt: Date
        var duration: TimeInterval
        var participants: [String] = []
        var meetingTitle: String?
        var titleSource: TitleSource = .user
        var cues: [SpeakerCue] = []
        var tileCues: [SpeakerCue] = []
        var mixedMedia: [TimeSpan] = []
        var suggestedProjectID: UUID?
        var requiresTranscript = false
        var importedFrom: ImportedFile?
    }

    let finalTranscription: FinalTranscription
    let speakerSeparation: SpeakerSeparation
    let noteBuilder: GroundedNoteBuilder
    let library: RecordingLibrary
    let makeTitle: (@MainActor @Sendable (TitleRequest) async -> String?)?

    init(
        finalTranscription: FinalTranscription,
        speakerSeparation: SpeakerSeparation,
        noteBuilder: GroundedNoteBuilder,
        library: RecordingLibrary,
        makeTitle: (@MainActor @Sendable (TitleRequest) async -> String?)? = nil
    ) {
        self.finalTranscription = finalTranscription
        self.speakerSeparation = speakerSeparation
        self.noteBuilder = noteBuilder
        self.library = library
        self.makeTitle = makeTitle
    }

    @discardableResult
    func finalize(
        _ draft: Draft,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Recording {
        let recording = try await build(draft, progress: progress)
        try library.add(recording)
        return recording
    }

    /// Renders the finished Recording without storing it, so a caller that
    /// filed a placeholder first can fold the user's interim edits back in.
    func build(
        _ draft: Draft,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Recording {
        let transcription = try await transcribeAndSeparateSpeakers(draft, progress: progress)
        let vocabulary = library.vocabulary(forProject: draft.suggestedProjectID)
        let segments = VocabularyCorrector.apply(vocabulary, to: transcription?.segments ?? [])
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

        let finishedTitle: String
        if let draftTitle = draft.title {
            finishedTitle = draftTitle
        } else {
            finishedTitle = await Self.title(
                for: segments,
                transcript: transcript,
                draft: draft,
                makeTitle: makeTitle
            )
        }

        var recording = Recording(
            id: draft.id,
            title: finishedTitle,
            transcript: transcript,
            segments: segments,
            speakers: transcription?.speakers ?? [],
            expectedParticipants: draft.participants.isEmpty ? nil : draft.participants,
            note: note,
            createdAt: draft.createdAt,
            duration: draft.duration,
            projectID: draft.suggestedProjectID,
            mixedMediaSpans: draft.mixedMedia.isEmpty ? nil : draft.mixedMedia,
            importedFrom: draft.importedFrom
        )
        recording.titleSource = draft.title == nil ? .automatic : draft.titleSource
        return recording
    }

    private static func title(
        for segments: [TranscriptSegment],
        transcript: String,
        draft: Draft,
        makeTitle: (@MainActor @Sendable (TitleRequest) async -> String?)?
    ) async -> String {
        await chooseTitle(
            segments: segments,
            transcript: transcript,
            calendarTitle: draft.meetingTitle,
            date: draft.createdAt,
            makeTitle: makeTitle
        )
    }

    static func chooseTitle(
        segments: [TranscriptSegment],
        transcript: String,
        calendarTitle: String?,
        date: Date,
        makeTitle: (@MainActor @Sendable (TitleRequest) async -> String?)?
    ) async -> String {
        let language = segments.lazy.compactMap(\.language).first
        let calendarTitle = calendarTitle.flatMap(TitleText.cleaned)
        let request = TitleRequest(segments: segments, calendarTitle: calendarTitle, language: language)
        if let makeTitle, let generated = await makeTitle(request).flatMap(TitleText.cleaned) {
            return generated
        }
        if let calendarTitle {
            return calendarTitle
        }
        return RecordingTitle.from(transcript: transcript, date: date, language: language)
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
        return GuestNaming.name(separated, cues: draft.cues + draft.tileCues, ownerName: naming.ownerName)
    }
}
