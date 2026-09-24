import SwiftUI

struct LibraryView: View {
    let library: Library
    let models: ModelInstallers
    let entitlements: Entitlements
    let coordinator: RecordingCoordinator
    let setup: SetupFlow
    let sync: SyncEngine
    let diagnostics: Diagnostics
    @Bindable var navigation: LibraryNavigation

    @State private var isCapturing = false
    @State private var isShowingSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionError: String?
    @State private var query = ""
    @State private var evidenceTime: TimeInterval?

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
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
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    recordButton
                        .buttonStyle(.borderedProminent)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                #endif
            }
        } detail: {
            Group {
                if let recording = selected {
                    RecordingDetailView(recording: recording, library: library, startAt: evidenceTime)
                        .id(recording.id)
                } else {
                    PrivacyWelcomeView(canRecord: coordinator.canStart, startRecording: startRecording)
                }
            }
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    recordButton
                }
            }
            #endif
        }
        .sheet(isPresented: $isCapturing) {
            CaptureView(coordinator: coordinator)
        }
        .sheet(isPresented: showsSetup) {
            SetupView(flow: setup, models: models)
                .interactiveDismissDisabled()
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                library: library,
                models: models,
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
    }

    @ViewBuilder
    private var emptyState: some View {
        switch library.state {
        case .locked, .unlocking:
            ProgressView("Opening Your Library")
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
                    .disabled(!coordinator.canStart)
            }
        case .unlocked:
            EmptyView()
        }
    }

    private var selected: Recording? {
        library.recordings.first { $0.id == navigation.selection }
    }

    private var results: [SearchResult] {
        LibrarySearch.results(
            for: query,
            in: library.recordings,
            semanticIndex: entitlements.allows(.semanticSearch) ? library.semanticIndex : nil
        )
    }

    private func open(_ result: SearchResult) {
        navigation.selection = result.recordingID
        evidenceTime = result.time
    }

    private var recordButton: some View {
        Button(
            coordinator.isRecording ? "Stop Recording" : "Record",
            systemImage: coordinator.isRecording ? "stop.circle.fill" : "record.circle.fill",
            action: startRecording
        )
        #if os(macOS)
        .labelStyle(.titleAndIcon)
        #endif
        .disabled(!coordinator.isRecording && !coordinator.canStart)
        .tint(.red)
        .symbolEffect(.pulse, isActive: coordinator.isRecording && !reduceMotion)
        #if os(iOS)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        #endif
    }

    private func startRecording() {
        guard coordinator.isRecording || coordinator.canStart else { return }

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
            if navigation.selection == recording.id { navigation.selection = nil }
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
