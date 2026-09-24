import SwiftUI

struct CaptureView: View {
    let coordinator: RecordingCoordinator

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tick = Date.now

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Label(coordinator.isRecording ? "Recording on This Device" : "Not Recording", systemImage: "lock.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(elapsed.recordingDurationText)
                    .font(.system(size: 56, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(coordinator.isRecording ? .primary : .secondary)
                    .accessibilityLabel("Recorded so far")
                    .accessibilityValue(elapsed.recordingDurationText)
            }
            .padding(.top, 8)

            ScrollView {
                Text(draftText)
                    .font(.title3)
                    .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .defaultScrollAnchor(.bottom)
            .frame(minHeight: 220)
            .background(.fill.quaternary, in: .rect(cornerRadius: 16))

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

            ZStack {
                HStack {
                    Button("Cancel", role: .cancel) {
                        Task {
                            await coordinator.cancel()
                            dismiss()
                        }
                    }
                    Spacer()
                }

                Button(action: save) {
                    Label("Save Recording", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(.record, in: .circle)
                        .symbolEffect(.pulse, isActive: coordinator.isRecording && !reduceMotion)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!coordinator.canStop)
                .opacity(coordinator.canStop ? 1 : 0.4)
            }
        }
        .padding(28)
        .stillSheetWidth(mac: 480, minHeight: 480)
        .interactiveDismissDisabled(coordinator.isRecording)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick = .now
            }
        }
    }

    private func save() {
        Task {
            await coordinator.stopAndSave()
            if coordinator.phase != .failed(""), coordinator.workflow == nil {
                dismiss()
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
            return message
        }
        if let workflow = coordinator.workflow, !workflow.showsDraft {
            return "Still is recording. The transcript appears when you save. Live transcript is part of Still Pro."
        }
        return transcript.isEmpty ? "Listening…" : transcript
    }
}
