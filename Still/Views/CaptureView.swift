import SwiftUI

struct CaptureView: View {
    let library: Library
    let entitlements: Entitlements

    @Environment(\.dismiss) private var dismiss
    @State private var workflow: RecordingWorkflow?
    @State private var tick = Date.now
    @State private var startupError: String?

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

            Image(systemName: isCapturing ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 72))
                .foregroundStyle(isCapturing ? .red : .secondary)
                .symbolEffect(.pulse, isActive: isCapturing)

            ScrollView {
                Text(draftText)
                    .font(.title3)
                    .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220)

            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    workflow?.cancel()
                    dismiss()
                }

                Spacer()

                Button("Save recording", systemImage: "stop.fill") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(workflow?.canSave != true)
            }
        }
        .padding(28)
        .frame(minWidth: 420, idealWidth: 560, minHeight: 480)
        .interactiveDismissDisabled(isCapturing)
        .task {
            do {
                let workflow = RecordingWorkflow(
                    session: LiveTranscriber(),
                    offlineTranscriber: SpeechOfflineTranscriber(),
                    recorder: try library.makeRecorder(),
                    library: library,
                    showsLiveDraft: entitlements.allows(.liveTranscript)
                )
                self.workflow = workflow
                await workflow.start()
            } catch {
                startupError = error.localizedDescription
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick = .now
            }
        }
        .onDisappear {
            workflow?.cancel()
        }
    }

    private var transcript: String {
        workflow?.transcript ?? ""
    }

    private var isCapturing: Bool {
        workflow?.isCapturing ?? false
    }

    private var elapsed: TimeInterval {
        _ = tick
        return workflow?.elapsed ?? 0
    }

    private var failureMessage: String? {
        if let startupError { return startupError }
        if case .failed(let message) = workflow?.state { return message }
        return nil
    }

    private var draftText: String {
        if let workflow, !workflow.showsDraft {
            return "Still is recording. The transcript appears when you save. Live transcript is part of Still Pro."
        }
        return transcript.isEmpty ? "Listening…" : transcript
    }

    private func save() async {
        guard let workflow else { return }

        await workflow.save()
        if workflow.state == .saved {
            dismiss()
        }
    }
}
