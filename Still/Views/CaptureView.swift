import SwiftUI

struct CaptureView: View {
    let coordinator: RecordingCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var tick = Date.now

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Label("On-device", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(elapsed.recordingDurationText)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
            }

            Image(systemName: coordinator.isRecording ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 72))
                .foregroundStyle(coordinator.isRecording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: coordinator.isRecording)

            ScrollView {
                Text(draftText)
                    .font(.title3)
                    .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220)

            if let note = coordinator.workflow?.captureNote {
                Label(note, systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .failed(let message) = coordinator.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    Task {
                        await coordinator.cancel()
                        dismiss()
                    }
                }

                Spacer()

                Button("Save recording", systemImage: "stop.fill") {
                    Task {
                        await coordinator.stopAndSave()
                        if coordinator.phase != .failed(""), coordinator.workflow == nil {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.canStop)
            }
        }
        .padding(28)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 480)
        .interactiveDismissDisabled(coordinator.isRecording)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick = .now
            }
        }
    }

    private var transcript: String {
        coordinator.workflow?.transcript ?? ""
    }

    private var elapsed: TimeInterval {
        _ = tick
        return coordinator.elapsed
    }

    private var draftText: String {
        if let message = coordinator.workflow?.draftFailure {
            return "Live transcript stopped: \(message) Still keeps recording and transcribes the audio when you save."
        }
        if let workflow = coordinator.workflow, !workflow.showsDraft {
            return "Still is recording. The transcript appears when you save. Live transcript is part of Still Pro."
        }
        return transcript.isEmpty ? "Listening…" : transcript
    }
}
