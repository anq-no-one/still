import SwiftUI

struct LibraryView: View {
    let library: Library
    let modelInstaller: ModelPackInstaller
    let entitlements: Entitlements
    let coordinator: RecordingCoordinator
    let setup: SetupFlow
    let sync: SyncEngine
    let diagnostics: Diagnostics
    #if os(macOS)
    let automatic: AutomaticRecording
    let browser: BrowserMeetingBridge
    #endif

    @State private var selection: Recording.ID?
    @State private var isCapturing = false
    @State private var isSettingUpModel = false
    @State private var isShowingPro = false
    @State private var isShowingSync = false
    @State private var isShowingSecurity = false
    @State private var isShowingRetention = false
    @State private var isShowingAutomatic = false
    @State private var isShowingBrowser = false
    @State private var isShowingDiagnostics = false
    @State private var actionError: String?
    @State private var query = ""
    @State private var evidenceTime: TimeInterval?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if query.isEmpty {
                    ForEach(library.recordings) { recording in
                        RecordingRow(recording: recording)
                            .tag(recording.id)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    delete(recording)
                                }
                            }
                    }
                } else {
                    ForEach(results) { result in
                        SearchResultRow(result: result)
                            .tag(result.recordingID)
                            .onTapGesture { open(result) }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search recordings")
            .navigationTitle("Recordings")
            .overlay {
                emptyState
            }
            .toolbar {
                ToolbarItem {
                    Button("Set up transcription", systemImage: "waveform.badge.mic") {
                        isSettingUpModel = true
                    }
                }

                ToolbarItem {
                    Button("Still Pro", systemImage: "sparkles") {
                        isShowingPro = true
                    }
                }

                ToolbarItem {
                    Button("Sync", systemImage: sync.isEnabled ? "arrow.triangle.2.circlepath" : "icloud.slash") {
                        isShowingSync = true
                    }
                }

                ToolbarItem {
                    Button("Keys and devices", systemImage: "key") {
                        isShowingSecurity = true
                    }
                }

                ToolbarItem {
                    Button("Audio and deletion", systemImage: "clock.arrow.circlepath") {
                        isShowingRetention = true
                    }
                }

                ToolbarItem {
                    Button("Diagnostics", systemImage: "stethoscope") {
                        isShowingDiagnostics = true
                    }
                }

                #if os(macOS)
                ToolbarItem {
                    Button("Automatic recording", systemImage: "bolt.badge.clock") {
                        isShowingAutomatic = true
                    }
                }

                ToolbarItem {
                    Button("Browser meetings", systemImage: "safari") {
                        isShowingBrowser = true
                    }
                }
                #endif

                ToolbarItem(placement: .primaryAction) {
                    Button(coordinator.isRecording ? "Recording" : "Record", systemImage: "record.circle") {
                        isCapturing = true
                        if !coordinator.isRecording {
                            Task { await coordinator.start() }
                        }
                    }
                    .disabled(library.state != .unlocked)
                    .symbolEffect(.pulse, isActive: coordinator.isRecording)
                }
            }
        } detail: {
            if let recording = selected {
                RecordingDetailView(recording: recording, library: library, startAt: evidenceTime)
                    .id(recording.id)
            } else {
                PrivacyWelcomeView(startRecording: {
                    isCapturing = true
                    Task { await coordinator.start() }
                })
            }
        }
        .sheet(isPresented: $isCapturing) {
            CaptureView(coordinator: coordinator)
        }
        .sheet(isPresented: $isSettingUpModel) {
            ModelSetupView(installer: modelInstaller)
        }
        .sheet(isPresented: showsSetup) {
            SetupView(flow: setup, installer: modelInstaller, entitlements: entitlements)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $isShowingPro) {
            ProUnlockView(entitlements: entitlements)
        }
        .sheet(isPresented: $isShowingSync) {
            SyncSettingsView(engine: sync, entitlements: entitlements)
        }
        .sheet(isPresented: $isShowingSecurity) {
            SecuritySettingsView(library: library)
        }
        .sheet(isPresented: $isShowingRetention) {
            RetentionSettingsView(library: library)
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            DiagnosticsSettingsView(diagnostics: diagnostics)
        }
        #if os(macOS)
        .sheet(isPresented: $isShowingAutomatic) {
            AutomaticRecordingSettingsView(automatic: automatic)
        }
        .sheet(isPresented: $isShowingBrowser) {
            BrowserMeetingSettingsView(bridge: browser)
        }
        #endif
        .alert("Still could not finish that", isPresented: showsActionError) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .onChange(of: coordinator.isRecording) { _, isRecording in
            if isRecording { isCapturing = true }
        }
        .onChange(of: setup.wantsPro) { _, wantsPro in
            isShowingPro = wantsPro
        }
        .task {
            await library.unlock()
            await entitlements.refresh()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch library.state {
        case .locked, .unlocking:
            ContentUnavailableView(
                "Library locked",
                systemImage: "lock.fill",
                description: Text("Authenticate to open your recordings.")
            )
        case .failed(let message):
            ContentUnavailableView {
                Label("Library locked", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    Task { await library.unlock() }
                }
            }
        case .unlocked where library.recordings.isEmpty:
            ContentUnavailableView(
                "No recordings yet",
                systemImage: "waveform",
                description: Text("Record your first private, on-device transcript.")
            )
        case .unlocked:
            EmptyView()
        }
    }

    private var selected: Recording? {
        library.recordings.first { $0.id == selection }
    }

    private var results: [SearchResult] {
        LibrarySearch.results(for: query, in: library.recordings)
    }

    private func open(_ result: SearchResult) {
        selection = result.recordingID
        evidenceTime = result.time
    }

    private var showsSetup: Binding<Bool> {
        Binding(get: { !setup.isComplete }, set: { _ in })
    }

    private var showsActionError: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private func delete(_ recording: Recording) {
        do {
            if selection == recording.id { selection = nil }
            try library.delete(recording)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.snippet)
                .font(.body)
                .lineLimit(3)

            HStack {
                Text(label)
                if let time = result.time {
                    Text(time.recordingDurationText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var label: String {
        switch result.match {
        case .title: "Title"
        case .transcript: "Transcript"
        case .note: "Note"
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(2)

            HStack {
                Text(recording.createdAt, format: .dateTime.day().month().hour().minute())
                Spacer()
                Text(recording.duration.recordingDurationText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
