import SwiftUI

struct SetupView: View {
    let flow: SetupFlow
    let installer: ModelPackInstaller

    var body: some View {
        Group {
            switch flow.step {
            case .privacy:
                privacyStep
            case .microphone:
                microphoneStep
            case .systemAudio:
                systemAudioStep
            case .transcription:
                transcriptionStep
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .stillSheetWidth(mac: 440, minHeight: 520)
        .animation(.default, value: flow.step)
        .task {
            while !Task.isCancelled {
                flow.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var privacyStep: some View {
        step(
            icon: "lock.shield.fill",
            title: "Your Recordings Stay Here",
            body: "Still records, transcribes, and stores everything on this device. There is no account, and nothing is sent anywhere until you ask for it."
        ) {
            primary("Continue", action: flow.acknowledgePrivacy)
        }
    }

    private var microphoneStep: some View {
        step(
            icon: "mic.fill",
            title: "Let Still Hear You",
            body: flow.microphone == .denied
                ? "Still cannot record without the microphone. Turn on Still in Privacy & Security → Microphone, then come back."
                : "Still needs the microphone to record you. Everything it hears stays on this device."
        ) {
            primary(flow.microphone == .denied ? "Open System Settings" : "Allow Microphone") {
                Task { await flow.requestMicrophone() }
            }
        }
    }

    private var systemAudioStep: some View {
        step(
            icon: "person.2.wave.2.fill",
            title: "Hear Everyone on the Call",
            body: flow.systemAudio == .denied
                ? "Turn on Still in Privacy & Security → Screen & System Audio Recording. Still records only sound, never your screen."
                : "To record the other people on a call, macOS asks you to allow Screen & System Audio Recording. Still records only sound, never your screen."
        ) {
            primary(flow.systemAudio == .denied ? "Open System Settings" : "Allow", action: flow.requestSystemAudio)
            if flow.systemAudio == .denied {
                secondary("I Allowed It — Reopen Still", action: SystemSetupPermissions.relaunch)
            }
        }
    }

    private var transcriptionStep: some View {
        step(
            icon: "waveform",
            title: "Transcribe on This Device",
            body: installer.pack.purpose
        ) {
            switch installer.state {
            case .installing, .verifying:
                ProgressView(value: installer.progress) {
                    Text("Downloading…")
                }
            case .failed:
                primary("Try Again") {
                    Task { await installer.approveAndInstall() }
                }
            default:
                primary("Download \(installer.pack.downloadSizeText)") {
                    Task { await installer.approveAndInstall() }
                }
            }
        }
    }

    private func step<Actions: View>(
        icon: String,
        title: LocalizedStringKey,
        body text: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            Image(systemName: icon)
                .font(.system(size: 56, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(height: 72)
                .accessibilityHidden(true)

            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = installer.state, flow.step == .transcription {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 24)

            VStack(spacing: 12) {
                actions()
            }
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
    }

    private func primary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
    }
}
