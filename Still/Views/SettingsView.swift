import SwiftUI

struct SettingsView: View {
    let library: Library
    let modelInstaller: ModelPackInstaller
    let entitlements: Entitlements
    let sync: SyncEngine
    let diagnostics: Diagnostics
    #if os(macOS)
    let automatic: AutomaticRecording
    let browser: BrowserMeetingBridge
    let chromium: ChromiumConnections
    #endif

    var body: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") {
                TranscriptionSettingsView(installer: modelInstaller)
            }
            Tab("Recording", systemImage: "record.circle") {
                Form {
                    AutomaticRecordingSettingsView(automatic: automatic)
                    BrowserMeetingSettingsView(bridge: browser, chromium: chromium)
                }
                .formStyle(.grouped)
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                SyncSettingsView(engine: sync)
            }
            Tab("Security", systemImage: "key") {
                SecuritySettingsView(library: library)
            }
            Tab("Storage", systemImage: "internaldrive") {
                RetentionSettingsView(library: library)
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
            modelInstaller: modelInstaller,
            entitlements: entitlements,
            sync: sync,
            diagnostics: diagnostics
        )
        #endif
    }
}

#if os(iOS)
private struct SettingsList: View {
    let library: Library
    let modelInstaller: ModelPackInstaller
    let entitlements: Entitlements
    let sync: SyncEngine
    let diagnostics: Diagnostics

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
                    link("Transcription", systemImage: "waveform", color: .blue) {
                        TranscriptionSettingsView(installer: modelInstaller)
                    }
                    link("Sync", systemImage: "arrow.triangle.2.circlepath", color: .cyan) {
                        SyncSettingsView(engine: sync)
                    }
                }

                Section {
                    link("Keys and Devices", systemImage: "key.fill", color: .gray) {
                        SecuritySettingsView(library: library)
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
