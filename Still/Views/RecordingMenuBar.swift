#if os(macOS)
import SwiftUI

struct RecordingMenuBarLabel: View {
    let coordinator: RecordingCoordinator
    let hint: MediaPlaybackHint
    let automatic: AutomaticRecording

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(RecordingMenuBarPanel.statusText(for: coordinator))
            .onChange(of: coordinator.isRecording) { _, isRecording in
                isRecording ? hint.check(ignoring: automatic.triggeredBy) : hint.dismiss()
            }
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
    let microphones: MicrophoneChoice
    let navigation: LibraryNavigation
    let lock: AppLock
    let shortcut: RecordingShortcut
    let hint: MediaPlaybackHint

    @Environment(\.openWindow) private var openWindow
    @State private var tick = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            recordControl
            microphoneStatus

            AutomaticCaptureStatus(automatic: automatic)

            MediaPlaybackBanner(hint: hint)

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
                    .background(.record, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.isRecording && !coordinator.canStart)
            .opacity(coordinator.isRecording || coordinator.canStart ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.statusText(for: coordinator))
                    .font(.headline)
                Text(coordinator.isRecording ? elapsed : shortcutHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var microphoneStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(microphoneName, systemImage: "mic")
                .accessibilityLabel(String(localized: "Microphone: \(microphoneName)"))
            if let notice = microphones.fallbackNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var microphoneName: String {
        microphones.active?.name ?? String(localized: "No Microphone")
    }

    private var shortcutHint: String {
        shortcut.combo.map { String(localized: "\($0.displayText) starts and stops from anywhere") } ?? ""
    }

    private var elapsed: String {
        _ = tick
        return coordinator.elapsed.recordingDurationText
    }

    private var recent: [Recording] {
        guard !lock.isLocked else { return [] }
        return Array(library.recordings.prefix(5))
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

struct AutomaticCaptureStatus: View {
    let automatic: AutomaticRecording

    var body: some View {
        if let app = automatic.triggeringApp {
            VStack(alignment: .leading, spacing: 8) {
                Label("Recording a \(app.name) call", systemImage: "phone.fill")
                    .font(.callout.weight(.medium))
                if !automatic.isKept {
                    Text("Still keeps it once it looks like a meeting. A short microphone check is thrown away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if !automatic.isKept {
                        Button("Keep", action: automatic.keep)
                    }
                    Button("Throw Away", role: .destructive) {
                        Task { await automatic.discardAutomaticRecording() }
                    }
                }
                .controlSize(.small)
            }
        } else if let name = automatic.discardedCheck {
            Label("Threw away a short \(name) check that was not a meeting.", systemImage: "trash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
