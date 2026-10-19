import SwiftUI
import Translation

struct RecordingDetailView: View {
    let library: Library
    let extraction: MemoryExtraction
    let diagnostics: Diagnostics?
    let startAt: TimeInterval?
    let regenerateTitle: @MainActor (Recording) async -> String
    /// The Library's current copy, refreshed every render. The editor keeps a
    /// snapshot for editing, and catches up through it when rendering ends.
    let latest: Recording

    @State private var editor: RecordingEditor
    @State private var title: String
    @State private var noteText: String
    @State private var copiedNote = false
    @State private var copiedPrompt = false
    @State private var copyReset: Task<Void, Never>?
    @State private var showsTranslation = false
    @State private var translationFailure: String?
    @State private var vocabularyChanges: [VocabularyChange] = []
    @State private var findsNoVocabularyChanges = false
    @State private var isRegeneratingTitle = false
    @State private var transcriptBlocks: [TranscriptBlock]?
    @State private var visibleSegmentBudget = TranscriptPaging.initialSegmentBudget

    init(
        recording: Recording,
        library: Library,
        extraction: MemoryExtraction,
        diagnostics: Diagnostics? = nil,
        startAt: TimeInterval? = nil,
        regenerateTitle: @escaping @MainActor (Recording) async -> String
    ) {
        self.library = library
        self.diagnostics = diagnostics
        self.regenerateTitle = regenerateTitle
        self.extraction = extraction
        self.startAt = startAt
        self.latest = recording
        _editor = State(initialValue: RecordingEditor(recording: recording, library: library))
        _title = State(initialValue: recording.title)
        _noteText = State(initialValue: recording.note?.userText ?? "")
    }

    var body: some View {
        let _ = Perf.count("render.RecordingDetailView")
        Group {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
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
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if recording.isProcessing {
                    Label(
                        "Still is writing the full transcript and notes. You will be notified when it is ready.",
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                if !recording.isProjectConfirmed {
                    ProjectConfirmationBar(
                        suggested: library.project(withID: recording.projectID),
                        projects: library.activeProjects,
                        confirm: editor.confirmProject,
                        assign: editor.assign(toProject:),
                        create: { name in
                            let project = try library.createProject(named: name)
                            editor.assign(toProject: project.id)
                        }
                    )
                }

                if let message = editor.saveFailure ?? translationFailure {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                noteView

                MemorySectionsView(
                    recordingID: recording.id,
                    library: library,
                    extraction: extraction
                )

                if !recording.speakers.isEmpty {
                    SpeakerListView(
                        speakers: recording.speakers,
                        suggestions: recording.unclaimedParticipants,
                        rename: { editor.renameSpeaker($0, to: $1) },
                        confirmSuggestedName: editor.confirmSuggestedName(of:),
                        rejectSuggestedName: editor.rejectSuggestedName(of:),
                        merge: { editor.mergeSpeaker($0, into: $1) },
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

                transcriptSection
                    }
                    .padding(28)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .task(id: refreshKey) {
                    await loadTranscript()
                    scrollToStartTime(using: proxy)
                }
            }
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
                    .help("Translate to \(readingLanguageName)")
            }
            ToolbarItem {
                ExportMenu(recording: recording, library: library)
            }
            if let diagnostics, diagnostics.developer.allowsDebugBundle {
                ToolbarItem {
                    DebugBundleButton(diagnostics: diagnostics, library: library, recordingID: recording.id)
                }
            }
            ToolbarItem {
                Button("Regenerate Title", systemImage: "wand.and.stars") {
                    isRegeneratingTitle = true
                    Interactions.begin("title.regenerate", ["recordingID": recording.id.uuidString])
                    Task {
                        let generated = await regenerateTitle(editor.recording)
                        Interactions.reached("title.regenerate", "titleShown")
                        editor.applyGeneratedTitle(generated)
                        title = generated
                        isRegeneratingTitle = false
                    }
                }
                .disabled(recording.segments.isEmpty || isRegeneratingTitle)
                .help("Regenerate Title")
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
                .help("Apply Project Vocabulary")
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
        .onChange(of: latest) { _, updated in
            guard editor.recording.isProcessing, !updated.isProcessing, !editor.hasPendingSave else { return }
            editor.refresh(to: updated)
            title = updated.title
            noteText = updated.note?.userText ?? ""
            refreshTranscriptBlocks()
        }
        .perfScreen("detail")
        .onDisappear {
            let pending = editor
            Task { @MainActor in pending.saveNow() }
        }
    }

    private var recording: Recording {
        editor.recording
    }

    private var refreshKey: String {
        "\(latest.id.uuidString)-\(latest.updatedAt.timeIntervalSince1970)"
    }

    private func loadTranscript() async {
        transcriptBlocks = nil
        let key = refreshKey
        let segments = editor.recording.segments
        let span = Perf.begin("detail.loadTranscript")
        let blocks = await Task.detached(priority: .userInitiated) {
            Perf.measure("detail.groupTranscript", ["segments": String(segments.count)]) {
                TranscriptBlocks.group(
                    segments.filter {
                        !DisfluencyFilter.isFillerOnly($0.displayText, language: $0.language)
                    }
                )
            }
        }.value
        Perf.end(span, ["recordingID": latest.id.uuidString, "segments": String(segments.count), "blocks": String(blocks.count)])
        guard key == refreshKey else { return }
        transcriptBlocks = blocks
        Interactions.reached("open.recording", "transcriptShown", ["segments": String(segments.count)])
        if let covering = TranscriptPaging.budgetCovering(blocks, startAt: startAt) {
            visibleSegmentBudget = covering
        }
    }

    private func refreshTranscriptBlocks() {
        transcriptBlocks = Perf.measure("detail.refreshTranscriptBlocks", ["segments": String(recording.segments.count)]) {
            TranscriptBlocks.group(
                recording.segments.filter {
                    !DisfluencyFilter.isFillerOnly($0.displayText, language: $0.language)
                }
            )
        }
    }

    private func scrollToStartTime(using proxy: ScrollViewProxy) {
        guard let startAt, let blocks = transcriptBlocks else { return }
        guard let target = blocks.first(where: { $0.segments.contains { $0.start >= startAt } }) else { return }
        proxy.scrollTo(target.id, anchor: .top)
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
            noteActions

            NoteSectionView(title: "Summary", items: editor.note.summary)
            NoteSectionView(title: "Decisions", items: editor.note.decisions)
            NoteSectionView(title: "Action Items", items: editor.note.actions)

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

    private var noteActions: some View {
        HStack {
            Spacer()
            Button(copiedNoteTitle, systemImage: copiedNote ? "checkmark" : "doc.on.doc") {
                NoteClipboard.copy(RecordingDocument.plainText(for: editor.recording))
                copiedNote = true
                confirmCopy()
            }
            .accessibilityLabel(Text("Copy the whole note as text"))
            if !editor.note.isEmpty {
                Button(copiedPromptTitle, systemImage: copiedPrompt ? "checkmark" : "sparkles") {
                    NoteClipboard.copy(AIAssistPrompt.prompt(note: editor.note, title: editor.recording.title, recordedAt: editor.recording.createdAt))
                    copiedPrompt = true
                    confirmCopy()
                }
                .accessibilityLabel(Text("Copy a prompt for an external AI assistant"))
            }
        }
    }

    private var copiedNoteTitle: String {
        copiedNote ? String(localized: "Copied") : String(localized: "Copy Note")
    }

    private var copiedPromptTitle: String {
        copiedPrompt ? String(localized: "Copied") : String(localized: "Ask AI")
    }

    private func confirmCopy() {
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedNote = false
            copiedPrompt = false
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let blocks = transcriptBlocks {
            if recording.transcript.isEmpty {
                if recording.isProcessing {
                    Label("Writing the transcript…", systemImage: "waveform.badge.magnifyingglass")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView(
                        "No Transcript",
                        systemImage: "waveform.slash",
                        description: Text("This device could not turn the recording into text.")
                    )
                }
            } else if recording.segments.isEmpty {
                Text(recording.transcript)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let page = TranscriptPaging.visibleBlocks(blocks, segmentBudget: visibleSegmentBudget)
                ForEach(page.blocks) { block in
                    TranscriptBlockView(
                        block: block,
                        speaker: block.speakerID.flatMap { id in recording.speakers.first { $0.id == id } },
                        showsTranslation: showsTranslation,
                        isMixed: { segment in recording.mixedMediaSpans?.contains { $0.overlaps(segment) } ?? false },
                        correct: {
                            editor.correct($0, to: $1)
                            refreshTranscriptBlocks()
                        }
                    )
                }
                if page.hasMore {
                    Button("Show more of the transcript", systemImage: "chevron.down") {
                        visibleSegmentBudget += TranscriptPaging.pageSegmentBudget
                    }
                    .buttonStyle(.borderless)
                }
            }
        } else {
            ProgressView("Loading transcript…")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let speaker: Speaker?
    let showsTranslation: Bool
    let isMixed: (TranscriptSegment) -> Bool
    let correct: (TranscriptSegment, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TranscriptSpeakerHeader(speakerName: speaker?.name, start: block.start)

            ForEach(block.chunks()) { chunk in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chunk.segments) { segment in
                        SegmentRow(
                            showsTranslation: showsTranslation,
                            segment: segment,
                            speakerName: speaker?.name,
                            isMixed: isMixed(segment),
                            correct: { correct(segment, $0) }
                        )
                    }
                }

                if let last = chunk.segments.last, last.id != block.segments.last?.id {
                    TranscriptSpeakerHeader(speakerName: speaker?.name, start: last.end, isContinuation: true)
                }
            }
        }
    }
}

private struct TranscriptSpeakerHeader: View {
    let speakerName: String?
    let start: TimeInterval
    var isContinuation: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(initials)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.secondary))
                .accessibilityHidden(true)

            Text(speakerName ?? String(localized: "Unknown speaker"))
                .font(.subheadline.bold())

            Text(start.recordingDurationText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if isContinuation {
                Text(String(localized: "continued"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerName ?? "Unknown speaker"), \(start.recordingDurationText)")
    }

    private var initials: String {
        guard let speakerName, !speakerName.isEmpty else { return "?" }
        let words = speakerName.split(separator: " ")
        let first = words.first?.first.map(String.init) ?? ""
        let second = words.dropFirst().first?.first.map(String.init) ?? ""
        let pair = first + second
        return pair.isEmpty ? "?" : pair
    }
}

private struct SegmentRow: View {
    let showsTranslation: Bool
    let segment: TranscriptSegment
    let speakerName: String?
    let isMixed: Bool
    let correct: (String) -> Void

    @State private var text: String
    @FocusState private var isEditing: Bool
    @ScaledMetric(relativeTo: .caption) private var timeColumnWidth = 52

    init(
        showsTranslation: Bool,
        segment: TranscriptSegment,
        speakerName: String?,
        isMixed: Bool,
        correct: @escaping (String) -> Void
    ) {
        self.showsTranslation = showsTranslation
        self.segment = segment
        self.speakerName = speakerName
        self.isMixed = isMixed
        self.correct = correct
        _text = State(initialValue: segment.displayText)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.startText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(segment.startText), said by \(speakerName ?? "an unknown speaker")")

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
