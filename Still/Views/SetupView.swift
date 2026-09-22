import SwiftUI

struct SetupView: View {
    let flow: SetupFlow
    let installer: ModelPackInstaller
    let entitlements: Entitlements

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
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
        .padding(32)
        .frame(maxHeight: .infinity, alignment: .top)
        .stillSheetWidth(mac: 460)
    }

    private var privacyStep: some View {
        step(
            icon: "lock.shield",
            title: "Your recordings stay here",
            body: "Still records, transcribes, and stores everything on this device. There is no account, and nothing is sent anywhere until you ask for it."
        ) {
            Button("Continue", action: flow.acknowledgePrivacy)
                .buttonStyle(.borderedProminent)
        }
    }

    private var microphoneStep: some View {
        step(
            icon: "mic",
            title: "Let Still hear the room",
            body: "Still needs the microphone to record. macOS and iOS ask you directly, and you can change your mind later in Settings."
        ) {
            Button("Not now", role: .cancel, action: flow.skipMicrophone)
            Button("Allow microphone") {
                Task { await flow.requestMicrophone() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var transcriptionStep: some View {
        step(
            icon: "waveform.badge.mic",
            title: "Set up transcription",
            body: installer.pack.purpose
        ) {
            Button("Skip for now", role: .cancel, action: flow.finishTranscription)

            switch installer.state {
            case .installed:
                Button("Continue", action: flow.finishTranscription)
                    .buttonStyle(.borderedProminent)
            case .installing, .verifying:
                ProgressView(value: installer.progress)
            default:
                Button("Download \(installer.pack.downloadSizeText)") {
                    Task { await installer.approveAndInstall() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var proStep: some View {
        step(
            icon: "sparkles",
            title: "Still Pro is optional",
            body: "Recording, transcription, exact search, and text export are free. Pro adds the live transcript, Mac system audio, speaker groups, translation, notes, and sync — all still on this device."
        ) {
            Button("Stay on free", role: .cancel, action: flow.finishPro)
            Button("See Still Pro") {
                flow.wantsPro = true
                flow.finishPro()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func step<Actions: View>(
        icon: String,
        title: String,
        body text: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(title, systemImage: icon)
                .font(.title2.bold())

            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = installer.state, flow.step == .transcription {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 24)

            HStack {
                Spacer()
                actions()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
