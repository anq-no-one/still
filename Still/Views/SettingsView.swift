import SwiftUI

struct SettingsView: View {
    let library: Library
    let models: ModelInstallers
    let entitlements: Entitlements
    let sync: SyncEngine
    let diagnostics: Diagnostics
    let setup: SetupFlow
    let lock: AppLock
    #if os(macOS)
    let automatic: AutomaticRecording
    let browser: BrowserMeetingBridge
    let aiTools: MCPAccess
    let chromium: ChromiumConnections
    let microphones: MicrophoneChoice
    #endif

    var body: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") {
                TranscriptionSettingsView(models: models, library: library)
            }
            Tab("Access", systemImage: "hand.raised") {
                AccessSettingsView(setup: setup)
            }
            Tab("Recording", systemImage: "record.circle") {
                Form {
                    MicrophoneSettingsView(microphones: microphones)
                    AutomaticRecordingSettingsView(automatic: automatic)
                    BrowserMeetingSettingsView(bridge: browser, chromium: chromium)
                }
                .formStyle(.grouped)
            }
            Tab("Projects", systemImage: "folder") {
                ProjectsSettingsView(library: library)
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                SyncSettingsView(engine: sync)
            }
            Tab("Security", systemImage: "key") {
                SecuritySettingsView(library: library, lock: lock)
            }
            Tab("Storage", systemImage: "internaldrive") {
                RetentionSettingsView(library: library)
            }
            Tab("AI Tools", systemImage: "sparkles.rectangle.stack") {
                AIToolsSettingsView(access: aiTools, library: library)
            }
            Tab("Diagnostics", systemImage: "stethoscope") {
                DiagnosticsSettingsView(diagnostics: diagnostics)
            }
            if !Entitlements.everythingIsFree {
                Tab("Still Pro", systemImage: "sparkles") {
                    ProUnlockView(entitlements: entitlements)
                }
            }
        }
        .frame(width: 520, height: 460)
        #else
        SettingsList(
            library: library,
            models: models,
            entitlements: entitlements,
            sync: sync,
            diagnostics: diagnostics,
            setup: setup,
            lock: lock
        )
        #endif
    }
}

#if os(iOS)
private struct SettingsList: View {
    let library: Library
    let models: ModelInstallers
    let entitlements: Entitlements
    let sync: SyncEngine
    let diagnostics: Diagnostics
    let setup: SetupFlow
    let lock: AppLock

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !Entitlements.everythingIsFree {
                    Section {
                        link("Still Pro", systemImage: "sparkles", color: .purple) {
                            ProUnlockView(entitlements: entitlements)
                        }
                    }
                }

                Section {
                    link("Access", systemImage: "hand.raised.fill", color: .indigo) {
                        AccessSettingsView(setup: setup)
                    }
                    link("Projects", systemImage: "folder.fill", color: .orange) {
                        ProjectsSettingsView(library: library)
                    }
                    link("Transcription", systemImage: "waveform", color: .blue) {
                        TranscriptionSettingsView(models: models, library: library)
                    }
                    link("Sync", systemImage: "arrow.triangle.2.circlepath", color: .cyan) {
                        SyncSettingsView(engine: sync)
                    }
                }

                Section {
                    link("Keys and Devices", systemImage: "key.fill", color: .gray) {
                        SecuritySettingsView(library: library, lock: lock)
                    }
                    link("Audio and Deletion", systemImage: "trash.fill", color: .red) {
                        RetentionSettingsView(library: library)
                    }
                    link("Diagnostics", systemImage: "stethoscope", color: .green) {
                        DiagnosticsSettingsView(diagnostics: diagnostics)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func link<Destination: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        color: Color,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(color.gradient, in: .rect(cornerRadius: 7))
            }
        }
    }
}
#endif
