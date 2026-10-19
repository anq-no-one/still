import SwiftUI

struct SettingsView: View {
    let library: Library
    let models: ModelInstallers
    let entitlements: Entitlements
    let sync: SyncEngine
    let diagnostics: Diagnostics
    let setup: SetupFlow
    let lock: AppLock
    let preferences: SettingsPreferences
    let preferencesExporter: PreferencesExporter
    let preferencesImporter: PreferencesImporter
    #if os(macOS)
    let automatic: AutomaticRecording
    let browser: BrowserMeetingBridge
    let aiTools: MCPAccess
    let chromium: ChromiumConnections
    let microphones: MicrophoneChoice
    let shortcut: RecordingShortcut
    let login: LaunchAtLogin
    let mediaHint: MediaPlaybackHint
    #else
    @Environment(\.dismiss) private var dismiss
    #endif

    private var layout: SettingsLayout { preferences.layout }

    var body: some View {
        let _ = Perf.count("render.SettingsView")
        #if os(macOS)
        NavigationSplitView {
            List(selection: selectedPage) {
                ForEach(layout.sections) { section in
                    Section(section.title) {
                        ForEach(layout.pages(in: section)) { page in
                            SettingsPageLabel(page: page)
                                .tag(page)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 308, max: 392)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            destination(for: preferences.page)
                .navigationTitle(preferences.page.title)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 620)
        .stillAppearance(preferences)
        #else
        NavigationStack {
            List {
                ForEach(layout.sections) { section in
                    Section(section.title) {
                        ForEach(layout.pages(in: section)) { page in
                            NavigationLink {
                                destination(for: page)
                            } label: {
                                SettingsPageLabel(page: page)
                            }
                        }
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
        .stillAppearance(preferences)
        #endif
    }

    @ViewBuilder
    private func destination(for page: SettingsPage) -> some View {
        switch page {
        case .capture, .audio, .shortcuts, .aiTools:
            macDestination(for: page)
        case .projects:
            ProjectsSettingsView(library: library, sync: sync)
        case .vocabulary:
            VocabularySettingsView(library: library)
        case .sync:
            SyncSettingsView(engine: sync)
        case .models:
            ModelsSettingsView(models: models)
        case .speakers:
            SpeakersSettingsView(library: library)
        case .access:
            AccessSettingsView(setup: setup)
        case .security:
            SecuritySettingsView(library: library, lock: lock)
        case .storage:
            RetentionSettingsView(library: library)
        case .diagnostics:
            DiagnosticsSettingsView(diagnostics: diagnostics, library: library)
        case .appearance:
            AppearanceSettingsView(preferences: preferences)
        case .transfer:
            PreferencesTransferSettingsView(exporter: preferencesExporter, importer: preferencesImporter)
        case .pro:
            ProUnlockView(entitlements: entitlements)
        }
    }

    @ViewBuilder
    private func macDestination(for page: SettingsPage) -> some View {
        #if os(macOS)
        switch page {
        case .capture:
            Form {
                AutomaticRecordingSettingsView(automatic: automatic)
                BrowserMeetingSettingsView(bridge: browser, chromium: chromium)
            }
            .formStyle(.grouped)
        case .audio:
            Form {
                MicrophoneSettingsView(microphones: microphones)
            }
            .formStyle(.grouped)
        case .shortcuts:
            Form {
                RecordingControlsSettingsView(shortcut: shortcut, login: login, hint: mediaHint)
            }
            .formStyle(.grouped)
        case .aiTools:
            AIToolsSettingsView(access: aiTools, library: library)
        default:
            EmptyView()
        }
        #endif
    }

    #if os(macOS)
    private var selectedPage: Binding<SettingsPage?> {
        Binding(
            get: { preferences.page },
            set: { page in
                if let page { preferences.page = page }
            }
        )
    }
    #endif
}
