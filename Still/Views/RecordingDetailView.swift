import SwiftUI
import Translation

struct RecordingDetailView: View {
    let library: Library
    let extraction: MemoryExtraction
    let startAt: TimeInterval?

    @State private var editor: RecordingEditor
    @State private var player = RecordingPlayer()
    @State private var title: String
    @State private var noteText: String
    @State private var showsTranslation = false
    @State private var translationFailure: String?
    @State private var vocabularyChanges: [VocabularyChange] = []
    @State private var findsNoVocabularyChanges = false

    init(recording: Recording, library: Library, extraction: MemoryExtraction, startAt: TimeInterval? = nil) {
        self.library = library
        self.extraction = extraction
        self.startAt = startAt
        _editor = State(initialValue: RecordingEditor(recording: recording, library: library))
        _title = State(initialValue: recording.title)
        _noteText = State(initialValue: recording.note?.userText ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TextField("Title", text: $title, axis: .vertical)
                    .font(.largeTitle.bold())
                    .textFieldStyle(.plain)
                    .onChange(of: title) { _, value in editor.rename(to: value) }

                HStack(spacing: 14) {
                    Label(recording.createdAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                    Label(recording.duration.recordingDurationText, systemImage: "clock")
                    if let file = recording.importedFrom {
                        Label(file.name, systemImage: file.kind == .video ? "film" : "waveform")
                            .lineLimit(1)
                            .accessibilityLabel("Imported from \(file.name)")
                    }
                    if player.isPlaying {
                        Button("Pause", systemImage: "pause.fill") { player.pause() }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if !recording.isProjectConfirmed {
                    ProjectConfirmationBar(
                        suggested: library.project(withID: recording.projectID),
                        projects: library.activeProjects,
                        confirm: editor.confirmProject,
                        assign: editor.assign(toProject:)
                    )
                }

                if let message = editor.saveFailure ?? playbackMessage ?? translationFailure {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                MemorySectionsView(
                    recordingID: recording.id,
                    library: library,
                    extraction: extraction,
                    play: { player.play(from: $0) }
                )

                noteView

                if !recording.speakers.isEmpty {
                    SpeakerListView(
                        speakers: recording.speakers,
                        suggestions: recording.unclaimedParticipants,
                        rename: { editor.renameSpeaker($0, to: $1) },
                        confirmSuggestedName: editor.confirmSuggestedName(of:),
                        rejectSuggestedName: editor.rejectSuggestedName(of:),
                        remembersVoice: { library.remembersVoice(of: $0.name) },
                        setRemembersVoice: { speaker, remembers in
                            try? remembers ? library.rememberVoice(of: speaker.name) : library.forgetVoice(of: speaker.name)
                        }
                    )
                }

                if let spans = recording.mixedMediaSpans, !spans.isEmpty {
                    Label(
                        "Another browser tab played sound during \(spans.map(\.clockText).formatted(.list(type: .and))). It may be mixed into the transcript there.",
                        systemImage: "speaker.wave.2"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Divider()

                if recording.transcript.isEmpty {
                    ContentUnavailableView(
                        "No Transcript",
                        systemImage: "waveform.slash",
                        description: Text("This device could not turn the recording into text. The audio is saved, so you can still play it.")
                    )
                } else if recording.segments.isEmpty {
                    Text(recording.transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(recording.segments) { segment in
                        SegmentRow(
                            showsTranslation: showsTranslation,
                            segment: segment,
                            speaker: editor.speaker(of: segment),
                            isMixed: recording.mixedMediaSpans?.contains { $0.overlaps(segment) } ?? false,
                            play: { player.play(from: segment.start) },
                            correct: { editor.correct(segment, to: $0) }
                        )
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .navigationTitle(title)
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                Toggle("Translate to \(readingLanguageName)", systemImage: "translate", isOn: $showsTranslation)
                    .disabled(recording.segments.isEmpty)
            }
            ToolbarItem {
                ExportMenu(recording: recording, library: library)
            }
            ToolbarItem {
                Button("Apply Project Vocabulary", systemImage: "character.book.closed") {
                    vocabularyChanges = VocabularyCorrector.changes(
                        library.vocabulary(forProject: recording.projectID),
                        for: recording.segments
                    )
                    findsNoVocabularyChanges = vocabularyChanges.isEmpty
                }
                .disabled(library.vocabulary(forProject: recording.projectID).activeTerms.isEmpty)
            }
        }
        .alert("Nothing to Change", isPresented: $findsNoVocabularyChanges) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The project vocabulary matches nothing in the lines you have not corrected yourself.")
        }
        .sheet(isPresented: Binding(get: { !vocabularyChanges.isEmpty }, set: { if !$0 { vocabularyChanges = [] } })) {
            VocabularyReviewSheet(changes: vocabularyChanges) { accepted in
                editor.apply(accepted)
                vocabularyChanges = []
            } cancel: {
                vocabularyChanges = []
            }
        }
        .translationTask(translationConfiguration) { session in
            do {
                let translated = try await SegmentTranslator(engine: AppleTranslationEngine(session: session))
                    .translate(editor.recording.segments, into: readingLanguage)
                editor.applyTranslations(translated)
                translationFailure = nil
            } catch {
                translationFailure = error.localizedDescription
                showsTranslation = false
            }
        }
        .task {
            player.load((try? library.audio(for: recording)) ?? Data())
            if let startAt { player.play(from: startAt) }
        }
        .onDisappear {
            editor.saveNow()
        }
    }

    private var recording: Recording {
        editor.recording
    }

    private var playbackMessage: String? {
        switch player.state {
        case .noAudio where !recording.segments.isEmpty:
            "The audio for this recording was removed. The transcript is unchanged."
        case .unreadable(let message):
            message
        case .noAudio, .ready:
            nil
        }
    }

    private var readingLanguage: Locale.Language {
        Locale.current.language
    }

    private var readingLanguageName: String {
        Locale.current.localizedString(forLanguageCode: readingLanguage.languageCode?.identifier ?? "en")
            ?? "your language"
    }

    /// Nil until the user asks, so the system never prompts for a language pack
    /// on its own.
    private var translationConfiguration: TranslationSession.Configuration? {
        guard showsTranslation,
              let spoken = recording.segments.compactMap(\.language).first
        else { return nil }

        return TranslationSession.Configuration(
            source: Locale.Language(identifier: spoken),
            target: readingLanguage
        )
    }

    @ViewBuilder
    private var noteView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Note Format", selection: templateBinding) {
                ForEach(NoteTemplate.allCases, id: \.self) { template in
                    Text(template.title).tag(template)
                }
            }
            .pickerStyle(.segmented)

            NoteSectionView(title: "Summary", items: editor.note.summary, openEvidence: openEvidence)
            NoteSectionView(title: "Decisions", items: editor.note.decisions, openEvidence: openEvidence)
            NoteSectionView(title: "Action Items", items: editor.note.actions, openEvidence: openEvidence)

            VStack(alignment: .leading, spacing: 6) {
                Text("Your Notes")
                    .font(.headline)

                TextEditor(text: $noteText)
                    .frame(minHeight: 90)
                    .font(.body)
                    .accessibilityLabel("Your Notes")
                    .onChange(of: noteText) { _, value in editor.updateNoteText(value) }
            }
        }
    }

    private var templateBinding: Binding<NoteTemplate> {
        Binding(
            get: { editor.note.template },
            set: { editor.changeTemplate(to: $0) }
        )
    }

    private func openEvidence(_ item: NoteItem) {
        guard let first = item.sourceSegmentIDs.first,
              let segment = editor.segment(withID: first)
        else { return }

        player.play(from: segment.start)
    }
}

private struct SegmentRow: View {
    let showsTranslation: Bool
    let segment: TranscriptSegment
    let speaker: Speaker?
    let isMixed: Bool
    let play: () -> Void
    let correct: (String) -> Void

    @State private var text: String
    @FocusState private var isEditing: Bool
    @ScaledMetric(relativeTo: .caption) private var timeColumnWidth = 92

    init(
        showsTranslation: Bool,
        segment: TranscriptSegment,
        speaker: Speaker?,
        isMixed: Bool,
        play: @escaping () -> Void,
        correct: @escaping (String) -> Void
    ) {
        self.showsTranslation = showsTranslation
        self.segment = segment
        self.speaker = speaker
        self.isMixed = isMixed
        self.play = play
        self.correct = correct
        _text = State(initialValue: segment.displayText)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Button(action: play) {
                    Text(segment.startText)
                        .frame(minWidth: 44, minHeight: 44, alignment: .topLeading)
                        .contentShape(.rect)
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityHint("Plays the recording from \(segment.startText)")

                if let speaker {
                    Text(speaker.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isMixed {
                    Image(systemName: "speaker.wave.2")
                        .font(.caption2)
                        .foregroundStyle(.attention)
                        .accessibilityLabel("Other browser sound may be mixed in here")
                }
            }
            .frame(width: timeColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Transcript", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isEditing)
                    .foregroundStyle(segment.isUncertain && !segment.isCorrected ? .secondary : .primary)
                    .onChange(of: isEditing) { _, editing in
                        if !editing { correct(text) }
                    }

                if showsTranslation, let translation = segment.translation {
                    Text(translation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if segment.isCorrected {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("You corrected these words")
            } else if segment.isUncertain {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Still is unsure of these words")
            }
        }
    }
}
