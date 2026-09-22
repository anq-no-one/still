import SwiftUI

struct TranscriptionSettingsView: View {
    let installer: ModelPackInstaller

    var body: some View {
        Form {
            Section {
                LabeledContent("Download Size", value: installer.pack.downloadSizeText)
                LabeledContent("Runs On", value: "This Device Only")
                status
            } footer: {
                Text(installer.pack.purpose)
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Transcription")
    }

    @ViewBuilder
    private var status: some View {
        switch installer.state {
        case .needsApproval:
            Button("Download") { install() }
        case .installing, .verifying:
            ProgressView("Downloading…", value: installer.progress)
        case .installed:
            Label("Ready to Transcribe Offline", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Try Again") { install() }
            }
        }
    }

    private func install() {
        Task { await installer.approveAndInstall() }
    }
}
