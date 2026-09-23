import SwiftUI

struct TranscriptionSettingsView: View {
    let models: ModelInstallers

    var body: some View {
        Form {
            Section {
                LabeledContent("Download Size", value: models.transcription.pack.downloadSizeText)
                LabeledContent("Runs On", value: "This Device Only")
                ModelPackStatus(installer: models.transcription, ready: "Ready to Transcribe Offline")
            } footer: {
                Text(models.transcription.pack.purpose)
            }

            Section {
                LabeledContent("Download Size", value: models.speakers.pack.downloadSizeText)
                ModelPackStatus(installer: models.speakers, ready: "Ready to Tell Speakers Apart")
            } header: {
                Text("Speakers")
            } footer: {
                Text(models.speakers.pack.purpose)
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Transcription")
    }
}

private struct ModelPackStatus: View {
    let installer: ModelPackInstaller
    let ready: LocalizedStringKey

    var body: some View {
        switch installer.state {
        case .needsApproval:
            Button("Download") { install() }
        case .installing, .verifying:
            ProgressView("Downloading…", value: installer.progress)
        case .installed:
            Label(ready, systemImage: "checkmark.circle.fill")
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
