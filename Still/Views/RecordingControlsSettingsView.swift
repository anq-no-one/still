#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI

struct RecordingControlsSettingsView: View {
    let shortcut: RecordingShortcut
    let login: LaunchAtLogin
    let hint: MediaPlaybackHint

    @State private var warnsAboutMedia = true

    var body: some View {
        Section {
            LabeledContent("Start or Stop Recording") {
                ShortcutRecorder(shortcut: shortcut)
            }
            if let problem = shortcut.problem {
                Label(problem.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Toggle("Open Still at Login", isOn: Binding(get: { login.isEnabled }, set: login.set))
            if let problem = login.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Toggle("Warn When Music or Video Is Playing", isOn: $warnsAboutMedia)
                .onChange(of: warnsAboutMedia) { _, warns in warns ? hint.turnOn() : hint.turnOff() }
        } header: {
            Text("Controls")
        } footer: {
            Text("The shortcut works while another app is in front. Still never pauses or changes another app's playback; it only tells you when sound might end up in a recording.")
        }
        .onAppear { warnsAboutMedia = !hint.isOff }
    }
}

private struct ShortcutRecorder: View {
    let shortcut: RecordingShortcut

    @State private var isListening = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(isListening ? "Type a Shortcut…" : shortcut.combo?.displayText ?? String(localized: "None")) {
                isListening ? stopListening() : startListening()
            }
            .monospaced()
            .accessibilityHint("Press, then type the new shortcut. Escape cancels.")

            if shortcut.combo != .standard {
                Button("Reset", action: shortcut.resetToStandard)
                    .buttonStyle(.borderless)
            }
        }
        .onDisappear(perform: stopListening)
    }

    private func startListening() {
        isListening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopListening()
                return nil
            }
            shortcut.change(to: KeyCombo(event: event))
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isListening = false
    }
}

struct MediaPlaybackBanner: View {
    let hint: MediaPlaybackHint

    var body: some View {
        if !hint.playingBundleIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Sound is playing in \(names). Your microphone may pick it up.", systemImage: "speaker.wave.2")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("OK", action: hint.dismiss)
                    Button("Don't Warn Again", action: hint.turnOff)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 10))
        }
    }

    private var names: String {
        hint.playingBundleIDs
            .map { id in NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id }
            .formatted(.list(type: .and))
    }
}

extension KeyCombo {
    init(event: NSEvent) {
        var modifiers = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: UInt32(modifiers),
            key: event.charactersIgnoringModifiers ?? ""
        )
    }
}
#endif
