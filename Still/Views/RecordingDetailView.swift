import SwiftUI

struct RecordingDetailView: View {
    let library: Library
    let startAt: TimeInterval?

    @State private var editor: RecordingEditor
    @State private var player = RecordingPlayer()
    @State private var title: String
    @State private var noteText: String

    init(recording: Recording, library: Library, startAt: TimeInterval? = nil) {
        self.library = library
        self.startAt = startAt
        _editor = State(initialValue: RecordingEditor(recording: recording, library: library))
        _title = State(initialValue: recording.title)
        _noteText = State(initialValue: recording.note?.userText ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TextField("Recording title", text: $title)
                    .font(.largeTitle.bold())
                    .textFieldStyle(.plain)
                    .onChange(of: title) { _, value in editor.rename(to: value) }

                HStack(spacing: 14) {
                    Label(recording.createdAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                    Label(recording.duration.recordingDurationText, systemImage: "clock")
                    if player.isPlaying {
                        Button("Pause", systemImage: "pause.fill") { player.pause() }
                            .buttonStyle(.borderless)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let message = editor.saveFailure ?? player.loadFailure {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                noteView

                Divider()

                if recording.segments.isEmpty {
                    Text(recording.transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(recording.segments) { segment in
                        SegmentRow(
                            segment: segment,
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
        .navigationTitle(title)
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

    @ViewBuilder
    private var noteView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Note shape", selection: templateBinding) {
                ForEach(NoteTemplate.allCases, id: \.self) { template in
                    Text(template.title).tag(template)
                }
            }
            .pickerStyle(.segmented)

            NoteSectionView(title: "Summary", items: editor.note.summary, openEvidence: openEvidence)
            NoteSectionView(title: "Decisions", items: editor.note.decisions, openEvidence: openEvidence)
            NoteSectionView(title: "Action items", items: editor.note.actions, openEvidence: openEvidence)

            VStack(alignment: .leading, spacing: 6) {
                Text("Your notes")
                    .font(.headline)

                TextEditor(text: $noteText)
                    .frame(minHeight: 90)
                    .font(.body)
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
    let segment: TranscriptSegment
    let play: () -> Void
    let correct: (String) -> Void

    @State private var text: String
    @FocusState private var isEditing: Bool

    init(segment: TranscriptSegment, play: @escaping () -> Void, correct: @escaping (String) -> Void) {
        self.segment = segment
        self.play = play
        self.correct = correct
        _text = State(initialValue: segment.displayText)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(segment.startText, action: play)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .frame(width: 56, alignment: .leading)
                .accessibilityHint("Plays the recording from \(segment.startText)")

            TextField("Transcript", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isEditing)
                .foregroundStyle(segment.isUncertain && !segment.isCorrected ? .secondary : .primary)
                .onChange(of: isEditing) { _, editing in
                    if !editing { correct(text) }
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
