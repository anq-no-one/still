#if os(macOS)
import SwiftUI

struct RecordingMenuBarLabel: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(statusText)
    }

    private var symbol: String {
        switch coordinator.phase {
        case .idle: "waveform"
        case .preparing: "waveform.badge.plus"
        case .recording: "record.circle.fill"
        case .finalizing: "waveform.badge.magnifyingglass"
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusText: String {
        RecordingMenuBarContent.statusText(for: coordinator)
    }
}

struct RecordingMenuBarContent: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        Text(Self.statusText(for: coordinator))

        Divider()

        if coordinator.isRecording {
            Button("Stop and Save") {
                Task { await coordinator.stopAndSave() }
            }
            .disabled(!coordinator.canStop)

            Button("Discard Recording") {
                Task { await coordinator.cancel() }
            }
        } else {
            Button("Start Recording") {
                Task { await coordinator.start() }
            }
            .disabled(!coordinator.canStart)
        }
    }

    static func statusText(for coordinator: RecordingCoordinator) -> String {
        switch coordinator.phase {
        case .idle:
            "Still is idle"
        case .preparing:
            "Preparing to record"
        case .recording:
            "Recording \(coordinator.elapsed.recordingDurationText)"
        case .finalizing:
            "Finishing the transcript"
        case .ready:
            "Recording saved"
        case .failed(let message):
            message
        }
    }
}
#endif
