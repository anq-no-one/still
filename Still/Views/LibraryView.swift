import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let library: Library
    let models: ModelInstallers
    let entitlements: Entitlements
    let coordinator: RecordingCoordinator
    let importer: MediaImporter
    let setup: SetupFlow
    let sync: SyncEngine
    let diagnostics: Diagnostics
    let lock: AppLock
    let extraction: MemoryExtraction
    let preferences: SettingsPreferences
    @Bindable var navigation: LibraryNavigation

    @State private var isCapturing = false
    @State private var isShowingSettings = false
    @State private var isShowingTasks = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionError: String?
    @State private var query = ""
    @State private var projectFilter: ProjectScope?
    @State private var selectedIDs: Set<Recording.ID> = []

    var body: some View {
        NavigationSplitView {
            recordingList
            .contextMenu(forSelectionType: Recording.ID.self) { ids in
                if hasUnconfirmed(ids) {
                    Button("Confirm Project", systemImage: "checkmark.circle") {
                        confirmProjects(of: ids)
                    }
                }
                if !ids.isEmpty {
                    Menu("Move to Project", systemImage: "folder") {
                        ProjectAssignmentButtons(
                            projects: library.activeProjects,
                            current: sharedProjectID(of: ids)
                        ) { projectID in
                            assign(ids, to: projectID)
                        }
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
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, importer.canStart else { return false }
                importer.start(url)
                return true
            }
            .onChange(of: selectedIDs) { _, ids in
                navigation.selection = ids.count == 1 ? ids.first : nil
            }
            .onChange(of: navigation.selection, initial: true) { _, id in
                guard let id, !selectedIDs.contains(id) else { return }
                selectedIDs = [id]
            }
            #endif
            .toolbar {
                if !library.projects.isEmpty {
                    ToolbarItem {
                        projectFilterMenu
                    }
                    ToolbarItem {
                        Button("Tasks and Decisions", systemImage: "checklist") { isShowingTasks = true }
                    }
                }
                ToolbarItem {
                    Button("Import Audio or Video…", systemImage: "square.and.arrow.down") {
                        navigation.isChoosingMediaFile = true
                    }
                    .disabled(!importer.canStart)
                }
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
                    RecordingDetailView(recording: recording, library: library, extraction: extraction, startAt: navigation.startTime)
                        .id(recording.id)
                } else if let dashboard = detailDashboard {
                    DashboardView(dashboard: dashboard, library: library, open: openSource)
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
        .sheet(isPresented: $isShowingTasks) {
            ProjectTasksView(library: library, projects: filterableProjects, open: openSource)
        }
        .sheet(isPresented: $isCapturing) {
            CaptureView(coordinator: coordinator)
        }
        .sheet(isPresented: showsImport) {
            MediaImportView(importer: importer)
        }
        .fileImporter(isPresented: $navigation.isChoosingMediaFile, allowedContentTypes: MediaImporter.contentTypes) { result in
            if case .success(let url) = result {
                importer.start(url)
            }
        }
        .onChange(of: importer.phase) { _, phase in
            guard case .imported(let id) = phase else { return }
            query = ""
            projectFilter = nil
            navigation.selection = id
            importer.dismiss()
        }
        .onChange(of: importer.canStart, initial: true) { startHandedOverImport() }
        .onChange(of: navigation.handedOverFile) { startHandedOverImport() }
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
                diagnostics: diagnostics,
                setup: setup,
                lock: lock,
                preferences: preferences
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

    private var shownRecordings: [Recording] {
        guard let projectFilter else { return library.recordings }
        return library.recordings.filter { $0.projectScope == projectFilter }
    }

    private var results: [SearchResult] {
        LibrarySearch.results(
            for: query,
            in: shownRecordings,
            semanticIndex: entitlements.allows(.semanticSearch) ? library.semanticIndex : nil
        )
    }

    @ViewBuilder
    private var listRows: some View {
        #if os(iOS)
        if query.isEmpty, projectFilter == nil, let dashboard = shownDashboard {
            DashboardSections(dashboard: dashboard, library: library, open: openSource)
            Section("Recordings") {
                recordingRows
            }
        } else {
            recordingOrResultRows
        }
        #else
        recordingOrResultRows
        #endif
    }

    @ViewBuilder
    private var recordingOrResultRows: some View {
        if query.isEmpty {
            recordingRows
        } else {
            ForEach(results) { result in
                SearchResultRow(result: result)
                    .tag(result.recordingID)
                    .onTapGesture { open(result) }
            }
        }
    }

    private var recordingRows: some View {
        ForEach(shownRecordings) { recording in
            RecordingRow(recording: recording, project: library.project(withID: recording.projectID))
                .tag(recording.id)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        delete(recording)
                    }
                }
        }
    }

    @ViewBuilder
    private var recordingList: some View {
        #if os(macOS)
        List(selection: $selectedIDs) {
            listRows
        }
        #else
        List(selection: $navigation.selection) {
            listRows
        }
        #endif
    }

    private var filterableProjects: [Project] {
        library.projects.filter { library.projectSelection.includes(.project($0.id)) }
    }

    private var projectFilterMenu: some View {
        Menu {
            Picker("Project", selection: $projectFilter) {
                Text("All Projects").tag(ProjectScope?.none)
                if library.projectSelection.includes(.noProject) {
                    Text("No Project").tag(ProjectScope?.some(.noProject))
                }
                ForEach(filterableProjects) { project in
                    Label {
                        Text(project.name)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(project.color.color)
                    }
                    .tag(ProjectScope?.some(.project(project.id)))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                "Filter by Project",
                systemImage: projectFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
    }

    private func sharedProjectID(of ids: Set<Recording.ID>) -> UUID? {
        let projects = Set(library.recordings.filter { ids.contains($0.id) }.map(\.projectID))
        return projects.count == 1 ? projects.first ?? nil : nil
    }

    private func hasUnconfirmed(_ ids: Set<Recording.ID>) -> Bool {
        library.recordings.contains { ids.contains($0.id) && !$0.isProjectConfirmed }
    }

    private func confirmProjects(of ids: Set<Recording.ID>) {
        do {
            try library.confirmProjects(of: ids)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func assign(_ ids: Set<Recording.ID>, to projectID: UUID?) {
        do {
            try library.assign(ids, toProject: projectID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func open(_ result: SearchResult) {
        navigation.open(result.recordingID, at: result.time)
    }

    private func openSource(_ recordingID: UUID, at time: TimeInterval?) {
        query = ""
        projectFilter = nil
        navigation.open(recordingID, at: time)
    }

    private var shownDashboard: Dashboard? {
        guard !library.projects.isEmpty else { return nil }

        let dashboard = library.dashboard()
        return dashboard.isEmpty ? nil : dashboard
    }

    private var detailDashboard: Dashboard? {
        #if os(macOS)
        shownDashboard
        #else
        nil
        #endif
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

    private func startHandedOverImport() {
        guard let url = navigation.handedOverFile, importer.canStart else { return }

        navigation.handedOverFile = nil
        importer.start(url)
    }

    private var showsImport: Binding<Bool> {
        Binding(
            get: { importer.isImporting || importer.isFailed },
            set: { if !$0 { importer.dismiss() } }
        )
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
    let project: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(2)

            if !recording.isProjectConfirmed {
                UnconfirmedProjectBadge(suggested: project)
                    .font(.caption)
            } else if let project {
                ProjectBadge(project: project)
                    .font(.caption)
            }

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
