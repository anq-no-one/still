import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    let library: Library

    @State private var title: String
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
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let renameError {
                    Label(renameError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                Divider()

                Text(recording.transcript)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
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
