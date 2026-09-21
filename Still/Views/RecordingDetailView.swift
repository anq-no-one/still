import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    let library: Library

    @State private var title: String
    @State private var player = RecordingPlayer()
    @State private var renameError: String?

    init(recording: Recording, library: Library) {
        self.recording = recording
        self.library = library
        _title = State(initialValue: recording.title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TextField("Recording title", text: $title)
                    .font(.largeTitle.bold())
                    .textFieldStyle(.plain)
                    .onSubmit(rename)

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

                if let message = renameError ?? player.loadFailure {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                Divider()

                if recording.segments.isEmpty {
                    Text(recording.transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(recording.segments) { segment in
                        SegmentRow(segment: segment) { player.play(from: segment.start) }
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
        }
    }

    private func rename() {
        do {
            try library.rename(recording, to: title)
            renameError = nil
        } catch {
            renameError = error.localizedDescription
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(segment.startText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)

                Text(segment.text)
                    .font(.body)
                    .foregroundStyle(segment.isUncertain ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if segment.isUncertain {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Still is unsure of these words")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays the recording from \(segment.startText)")
    }
}
