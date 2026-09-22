import SwiftUI

struct LibraryView: View {
    let library: Library
    let modelInstaller: ModelPackInstaller
    let entitlements: Entitlements
    let coordinator: RecordingCoordinator
    let setup: SetupFlow
    let sync: SyncEngine
    let diagnostics: Diagnostics

    @State private var selection: Recording.ID?
    @State private var isCapturing = false
    @State private var isShowingPro = false
    @State private var isShowingSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .searchable(text: $query, prompt: "Search Recordings")
            .navigationTitle("Recordings")
            .overlay {
                emptyState
            }
            .toolbar {
                ToolbarItem(placement: recordPlacement) {
                    Button(
                        coordinator.isRecording ? "Stop Recording" : "Record",
                        systemImage: coordinator.isRecording ? "stop.circle.fill" : "record.circle.fill",
                        action: startRecording
                    )
                    .disabled(library.state != .unlocked)
                    .tint(.red)
                    .symbolEffect(.pulse, isActive: coordinator.isRecording && !reduceMotion)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    #if os(iOS)
                    .buttonStyle(.borderedProminent)
                    #endif
                }

                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                #endif
            }
        } detail: {
            if let recording = selected {
                RecordingDetailView(recording: recording, library: library, startAt: evidenceTime)
                    .id(recording.id)
            } else {
                PrivacyWelcomeView(startRecording: startRecording)
            }
        }
        .sheet(isPresented: $isCapturing) {
            CaptureView(coordinator: coordinator)
        }
        .sheet(isPresented: showsSetup) {
            SetupView(flow: setup, installer: modelInstaller)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $isShowingPro) {
            NavigationStack {
                ProUnlockView(entitlements: entitlements)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingPro = false }
                        }
                    }
            }
            .stillSheetWidth(mac: 420, minHeight: 420)
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                library: library,
                modelInstaller: modelInstaller,
                entitlements: entitlements,
                sync: sync,
                diagnostics: diagnostics
            )
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
                "Library Locked",
                systemImage: "lock.fill",
                description: Text("Authenticate to open your recordings.")
            )
        case .failed(let message):
            ContentUnavailableView {
                Label("Library Locked", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await library.unlock() }
                }
            }
        case .unlocked where library.recordings.isEmpty:
            ContentUnavailableView {
                Label("No Recordings Yet", systemImage: "waveform")
            } description: {
                Text("Record your first private, on-device transcript.")
            } actions: {
                Button("Record", systemImage: "record.circle.fill", action: startRecording)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
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

    /// The Mac has a toolbar; a phone has a thumb. Recording is the reason the
    /// app exists, so on iPhone it sits where the thumb already is.
    private var recordPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .primaryAction
        #endif
    }

    private func startRecording() {
        isCapturing = true
        if !coordinator.isRecording {
            Task { await coordinator.start() }
        }
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
