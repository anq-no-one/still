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
        var roster: [String] = []
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
        let segments = Perf.measure("finalize.vocabulary", ["recordingID": draft.id.uuidString]) {
            VocabularyCorrector.apply(vocabulary, to: transcription?.segments ?? [])
        }
        let transcript = segments.plainText
        guard !transcript.isEmpty || transcription == nil else {
            throw RecordingWorkflowError.emptyTranscript
        }

        let note = await Perf.trace("finalize.note", ["recordingID": draft.id.uuidString, "segments": String(segments.count)]) {
            await AITrace.$stage.withValue("note") {
                await noteBuilder.note(
                    segments: segments,
                    speakers: transcription?.speakers ?? [],
                    duration: draft.duration,
                    tracks: library.tracks(forRecording: draft.id)
                )
            }
        }
        try Task.checkCancellation()

        let finishedTitle: String
        if let draftTitle = draft.title {
            finishedTitle = draftTitle
        } else {
            finishedTitle = await Perf.trace("finalize.title", ["recordingID": draft.id.uuidString]) {
                await Self.title(
                    for: segments,
                    transcript: transcript,
                    draft: draft,
                    makeTitle: makeTitle
                )
            }
        }

        var recording = Recording(
            id: draft.id,
            title: finishedTitle,
            transcript: transcript,
            segments: segments,
            speakers: transcription?.speakers ?? [],
            expectedParticipants: Self.expectedParticipants(draft),
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

    private static func expectedParticipants(_ draft: Draft) -> [String]? {
        var names: [String] = []
        for name in draft.roster + draft.participants
        where !GuestNaming.isSelfEntry(name) && !names.contains(where: { VoiceProfiles.key(for: $0) == VoiceProfiles.key(for: name) }) {
            names.append(name)
        }
        return names.isEmpty ? nil : names
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
        if let makeTitle, let generated = await AITrace.$stage.withValue("title", operation: { await makeTitle(request) }).flatMap(TitleText.cleaned) {
            AITrace.record("title.chosen", ["source": "model", "title": generated, "calendarTitle": calendarTitle ?? "-"])
            return generated
        }
        if let calendarTitle {
            AITrace.record("title.chosen", ["source": "calendar", "title": calendarTitle])
            return calendarTitle
        }
        let fallback = RecordingTitle.from(transcript: transcript, date: date, language: language)
        AITrace.record("title.chosen", ["source": "keySentence", "title": fallback])
        return fallback
    }

    private func transcribeAndSeparateSpeakers(
        _ draft: Draft,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult? {
        let id = draft.id.uuidString
        let tracks = try Perf.measure("finalize.loadTracks", ["recordingID": id]) {
            try library.capturedTracks(forRecording: draft.id)
        }
        let audioSeconds = tracks.reduce(0) { $0 + $1.format.duration(ofBytes: $1.pcm.count) }
        let transcription: TranscriptionResult
        let transcribe = Perf.begin("finalize.transcribe")
        do {
            transcription = try await finalTranscription.run(
                tracks: tracks,
                checkpoints: try library.checkpointStore(forRecording: draft.id),
                progress: progress
            )
            let ms = Perf.end(transcribe, [
                "recordingID": id,
                "tracks": tracks.map(\.track.rawValue).joined(separator: ","),
                "audioS": String(format: "%.1f", audioSeconds),
                "segments": String(transcription.segments.count),
            ])
            DevLog.event("finalize.transcribe.speed", [
                "recordingID": id,
                "realtimeFactor": String(format: "%.3f", ms / 1000 / max(audioSeconds, 0.001)),
            ])
        } catch is TranscriptionError where !draft.requiresTranscript {
            Perf.end(transcribe, ["recordingID": id, "error": "transcriptionError"])
            return nil
        } catch {
            Perf.end(transcribe, ["recordingID": id, "error": String(describing: error)])
            throw error
        }
        var naming = library.speakerNaming
        naming.participants = draft.participants
        let separated = await Perf.trace("finalize.separateSpeakers", ["recordingID": id, "audioS": String(format: "%.1f", audioSeconds)]) {
            await speakerSeparation.separate(transcription, tracks: tracks, naming: naming)
        }
        AITrace.record("speakers.separated", [
            "stage": "speakers",
            "speakers": AITrace.speakers(separated.speakers),
            "segments": String(separated.segments.count),
        ])
        let named = Perf.measure("finalize.nameGuests", ["recordingID": id, "cues": String(draft.cues.count + draft.tileCues.count)]) {
            GuestNaming.name(separated, cues: draft.cues + draft.tileCues, roster: draft.roster, ownerName: naming.ownerName)
        }
        AITrace.record("speakers.named", [
            "stage": "speakers",
            "speakers": AITrace.speakers(named.speakers),
            "roster": draft.roster.joined(separator: ", "),
            "participants": draft.participants.joined(separator: ", "),
            "cues": (draft.cues + draft.tileCues).map { "\($0.name)@\(Int($0.start))-\(Int($0.end))" }.joined(separator: "; "),
        ])
        return named
    }
}
