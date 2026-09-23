#if os(macOS)
import SwiftUI

struct RecordingMenuBarLabel: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(RecordingMenuBarPanel.statusText(for: coordinator))
    }

    private var symbol: String {
        switch coordinator.phase {
        case .idle, .ready: "waveform"
        case .preparing: "waveform.badge.plus"
        case .recording: "record.circle.fill"
        case .finalizing: "waveform.badge.magnifyingglass"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct RecordingMenuBarPanel: View {
    let coordinator: RecordingCoordinator
    let library: Library
    let automatic: AutomaticRecording
    let navigation: LibraryNavigation

    @Environment(\.openWindow) private var openWindow
    @State private var tick = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            recordControl

            if coordinator.isRecording, let transcript = coordinator.workflow?.transcript, !transcript.isEmpty {
                Text(transcript.suffix(220))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !recent.isEmpty {
                Divider()
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(recent) { recording in
                    Button {
                        show(recording)
                    } label: {
                        HStack {
                            Text(recording.title)
                                .lineLimit(1)
                            Spacer()
                            Text(recording.duration.recordingDurationText)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Toggle("Record Calls Automatically", isOn: watching)
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack {
                Button("Open Library") { openLibrary() }
                SettingsLink {
                    Text("Settings…")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick = .now
            }
        }
    }

    private var recordControl: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Label(coordinator.isRecording ? "Stop and Save" : "Record", systemImage: coordinator.isRecording ? "stop.fill" : "record.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.red, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.isRecording && !coordinator.canStart)
            .opacity(coordinator.isRecording || coordinator.canStart ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.statusText(for: coordinator))
                    .font(.headline)
                Text(coordinator.isRecording ? elapsed : "⌥⌘R starts and stops from anywhere")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var elapsed: String {
        _ = tick
        return coordinator.elapsed.recordingDurationText
    }

    private var recent: [Recording] {
        Array(library.recordings.prefix(5))
    }

    private var watching: Binding<Bool> {
        Binding(
            get: { automatic.isWatching },
            set: { $0 ? automatic.startWatching() : automatic.stopWatching() }
        )
    }

    private func toggle() {
        Task { await coordinator.toggle() }
    }

    private func show(_ recording: Recording) {
        navigation.selection = recording.id
        openLibrary()
    }

    private func openLibrary() {
        openWindow(id: StillApp.libraryWindowID)
        NSApp.activate()
    }

    static func statusText(for coordinator: RecordingCoordinator) -> String {
        switch coordinator.phase {
        case .idle, .ready:
            coordinator.canStart ? String(localized: "Ready to Record") : String(localized: "Finish Setup to Record")
        case .preparing:
            String(localized: "Starting…")
        case .recording:
            String(localized: "Recording")
        case .finalizing:
            String(localized: "Writing the Transcript…")
        case .failed(let message):
            message
        }
    }
}
#endif
