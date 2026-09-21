import SwiftUI

struct ModelSetupView: View {
    let installer: ModelPackInstaller

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Set up transcription", systemImage: "waveform.badge.mic")
                .font(.title2.bold())

            Text(installer.pack.purpose)
                .font(.body)
                .foregroundStyle(.secondary)

            LabeledContent("Download size", value: installer.pack.downloadSizeText)
            LabeledContent("Where it runs", value: "This device only")

            switch installer.state {
            case .needsApproval:
                Text("Still makes no network request until you start this download.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .installing, .verifying:
                ProgressView(value: installer.progress)
            case .installed:
                Label("Ready to transcribe offline", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Not now", role: .cancel) { dismiss() }

                Spacer()

                Button(primaryTitle) {
                    if installer.state == .installed {
                        dismiss()
                    } else {
                        Task { await installer.approveAndInstall() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
        .padding(28)
        .frame(minWidth: 380, idealWidth: 460)
    }

    private var primaryTitle: String {
        switch installer.state {
        case .needsApproval: "Download"
        case .installing, .verifying: "Downloading…"
        case .installed: "Done"
        case .failed: "Try again"
        }
    }

    private var isWorking: Bool {
        switch installer.state {
        case .installing, .verifying: true
        default: false
        }
    }
}
