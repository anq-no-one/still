import SwiftData
import SwiftUI

struct RecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var transcriber = LiveTranscriber()
    @State private var startedAt = Date.now
    @State private var elapsed: TimeInterval = 0
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Label("On-device", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(elapsed.meetingDurationText)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
            }

            Image(systemName: transcriber.isRecording ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 72))
                .foregroundStyle(transcriber.isRecording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: transcriber.isRecording)

            ScrollView {
                Text(transcriber.transcript.isEmpty ? "Listening…" : transcriber.transcript)
                    .font(.title3)
                    .foregroundStyle(transcriber.transcript.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    transcriber.stop()
                    dismiss()
                }

                Spacer()

                Button("Save meeting", systemImage: "stop.fill") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 480)
        .interactiveDismissDisabled(transcriber.isRecording)
        .task {
            startedAt = .now
            do {
                try await transcriber.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if transcriber.isRecording {
                    elapsed = Date.now.timeIntervalSince(startedAt)
                }
            }
        }
        .onDisappear {
            transcriber.stop()
        }
    }

    private func save() {
        transcriber.stop()
        let transcript = transcriber.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = Meeting(
            title: MeetingTitle.from(transcript: transcript, date: startedAt),
            transcript: transcript,
            createdAt: startedAt,
            duration: elapsed
        )
        modelContext.insert(meeting)
        dismiss()
    }
}
