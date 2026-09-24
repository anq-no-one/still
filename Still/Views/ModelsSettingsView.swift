import SwiftUI

struct ModelsSettingsView: View {
    let models: ModelInstallers

    var body: some View {
        Form {
            Section {
                Text("Still picks the right model for each recording by itself. Models run only on this device and work offline once downloaded.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ModelPackSection(installer: models.transcription)
            ModelPackSection(installer: models.speakers)
            ModelPackSection(installer: models.meetingMemory)
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Models")
    }
}

private struct ModelPackSection: View {
    let installer: ModelPackInstaller

    @State private var showsLanguages = false

    var body: some View {
        Section {
            ModelPackStatus(installer: installer)
            LabeledContent("Download Size", value: installer.pack.downloadSizeText)
            LabeledContent("Runs On", value: String(localized: "This Device Only"))
            languages
        } header: {
            Text(installer.pack.name)
        } footer: {
            Text(installer.pack.purpose)
        }
    }

    @ViewBuilder
    private var languages: some View {
        switch installer.pack.languages {
        case .any:
            LabeledContent("Languages", value: String(localized: "Any Language"))
        case .only(let codes):
            DisclosureGroup(isExpanded: $showsLanguages) {
                Text(installer.pack.languages.names().formatted(.list(type: .and)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                LabeledContent("Languages", value: String(localized: "\(codes.count) Languages"))
            }
        }
    }
}

private struct ModelPackStatus: View {
    let installer: ModelPackInstaller

    var body: some View {
        switch installer.state {
        case .needsApproval:
            LabeledContent("Status") {
                HStack {
                    Text("Not Downloaded")
                        .foregroundStyle(.secondary)
                    Button("Download", action: install)
                }
            }
        case .installing, .verifying:
            ProgressView(value: installer.progress) {
                installer.state == .verifying ? Text("Verifying…") : Text("Downloading…")
            } currentValueLabel: {
                Text(installer.progress, format: .percent.precision(.fractionLength(0)))
            }
            .accessibilityValue(Text(installer.progress, format: .percent.precision(.fractionLength(0))))
        case .installed:
            LabeledContent("Status") {
                Label("Ready Offline", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: install)
            }
        }
    }

    private func install() {
        Task { await installer.approveAndInstall() }
    }
}
