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
            case .transcription:
                transcriptionStep
            case .pro:
                proStep
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .stillSheetWidth(mac: 440, minHeight: 520)
        .animation(.default, value: flow.step)
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
            title: "Let Still Hear the Room",
            body: "Still needs the microphone to record. The system asks you directly, and you can change your mind later in Settings."
        ) {
            primary("Allow Microphone") {
                Task { await flow.requestMicrophone() }
            }
            secondary("Not Now", action: flow.skipMicrophone)
        }
    }

    private var transcriptionStep: some View {
        step(
            icon: "waveform",
            title: "Transcribe on This Device",
            body: installer.pack.purpose
        ) {
            switch installer.state {
            case .installed:
                primary("Continue", action: flow.finishTranscription)
            case .installing, .verifying:
                ProgressView(value: installer.progress) {
                    Text("Downloading…")
                }
                secondary("Continue in Background", action: flow.finishTranscription)
            default:
                primary("Download \(installer.pack.downloadSizeText)") {
                    Task { await installer.approveAndInstall() }
                }
                secondary("Not Now", action: flow.finishTranscription)
            }
        }
    }

    private var proStep: some View {
        step(
            icon: "sparkles",
            title: "Still Pro Is Optional",
            body: "Recording, transcription, exact search, and text export are free. Pro adds the live transcript, Mac system audio, speakers, translation, notes, and sync — all still on this device."
        ) {
            primary("See Still Pro") {
                flow.wantsPro = true
                flow.finishPro()
            }
            secondary("Not Now", action: flow.finishPro)
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
