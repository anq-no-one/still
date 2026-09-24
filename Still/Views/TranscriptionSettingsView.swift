import SwiftUI

struct TranscriptionSettingsView: View {
    let models: ModelInstallers
    let library: Library

    @State private var ownerName = ""
    @State private var ownerNameFailure: String?

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
                TextField("Your Name", text: $ownerName, prompt: Text("First and last name"))
                    .onSubmit(saveOwnerName)
                if let ownerNameFailure {
                    Label(ownerNameFailure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                LabeledContent("Download Size", value: models.speakers.pack.downloadSizeText)
                ModelPackStatus(installer: models.speakers, ready: "Ready to Tell Speakers Apart")
            } header: {
                Text("Speakers")
            } footer: {
                Text(models.speakers.pack.purpose)
            }

            Section {
                if library.rememberedVoiceProfiles.isEmpty {
                    Text("No voices remembered")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.rememberedVoiceProfiles, id: \.name) { profile in
                    LabeledContent(profile.name) {
                        Button("Forget", role: .destructive) {
                            try? library.forgetVoice(of: profile.name)
                        }
                    }
                }
            } header: {
                Text("Remembered Voices")
            } footer: {
                Text("Still remembers a voice only when you turn it on for a named speaker. A remembered voice only suggests a name; you confirm it. Forgetting stops all future suggestions.")
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Transcription")
        .onAppear { ownerName = library.ownerName ?? "" }
        .onDisappear(perform: saveOwnerName)
    }

    private func saveOwnerName() {
        guard ownerName != (library.ownerName ?? "") else { return }
        do {
            try library.setOwnerName(ownerName)
            ownerNameFailure = nil
        } catch {
            ownerNameFailure = error.localizedDescription
        }
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
