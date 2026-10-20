import SwiftUI

struct ProjectsSettingsView: View {
    let library: Library
    let sync: SyncEngine

    @State private var failure: String?
    @State private var vocabularyProject: Project?

    var body: some View {
        Form {
            Section {
                ForEach(library.projects) { project in
                    ProjectEditorRow(project: project, save: save, editVocabulary: { vocabularyProject = project })
                }

                ProjectCreationField(create: { name in
                    _ = try library.createProject(named: name)
                })
            } header: {
                Text("Projects")
            } footer: {
                Text("Projects sync to your other devices, encrypted like your recordings.")
            }

            DeviceProjectSelectionSection(library: library, sync: sync)

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Projects")
        .sheet(item: $vocabularyProject) { project in
            VocabularyEditorView(library: library, project: project)
        }
    }

    private func save(_ project: Project) {
        do {
            try library.saveProject(project)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct ProjectEditorRow: View {
    let project: Project
    let save: (Project) -> Void
    let editVocabulary: () -> Void

    @State private var name: String

    init(project: Project, save: @escaping (Project) -> Void, editVocabulary: @escaping () -> Void) {
        self.project = project
        self.save = save
        self.editVocabulary = editVocabulary
        _name = State(initialValue: project.name)
    }

    var body: some View {
        HStack {
            Menu {
                Picker("Color", selection: colorBinding) {
                    ForEach(ProjectColor.allCases, id: \.self) { color in
                        Label {
                            Text(color.title)
                        } icon: {
                            color.swatch()
                        }
                        .tag(color)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                ProjectDot(color: project.color)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Color for \(project.name)"))

            TextField("Name", text: $name)
                .labelsHidden()
                .foregroundStyle(project.isArchived ? .secondary : .primary)
                .onSubmit(rename)

            Button("Vocabulary", action: editVocabulary)
                .buttonStyle(.borderless)

            Button(project.isArchived ? "Unarchive" : "Archive") {
                var updated = project
                updated.setArchived(!project.isArchived)
                save(updated)
            }
            .buttonStyle(.borderless)
        }
        .onChange(of: project.name) { _, value in name = value }
    }

    private var colorBinding: Binding<ProjectColor> {
        Binding(
            get: { project.color },
            set: { color in
                var updated = project
                updated.recolor(to: color)
                save(updated)
            }
        )
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else {
            name = project.name
            return
        }

        var updated = project
        updated.rename(to: trimmed)
        save(updated)
    }
}

private struct DeviceProjectSelectionSection: View {
    let library: Library
    let sync: SyncEngine

    var body: some View {
        Section {
            Picker("Show", selection: modeBinding) {
                Text("All Projects").tag(ProjectSelection.Mode.all)
                Text("Only These Projects").tag(ProjectSelection.Mode.only)
                Text("All Except These").tag(ProjectSelection.Mode.except)
            }

            scopeRow(.noProject) {
                Label("No Project", systemImage: "circle.dashed")
            }

            ForEach(library.projects) { project in
                scopeRow(.project(project.id)) {
                    ProjectBadge(project: project)
                }
            }
        } header: {
            Text(deviceTitle)
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private func scopeRow(_ scope: ProjectScope, @ViewBuilder label: () -> some View) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            label()
            ScopeStorageText(storage: library.storage(of: scope))
        }

        if library.projectSelection.mode == .all {
            content
        } else {
            Toggle(isOn: scopeBinding(scope)) { content }
        }
    }

    private var deviceTitle: LocalizedStringKey {
        #if os(macOS)
        "On This Mac"
        #else
        "On This Device"
        #endif
    }

    private var footer: LocalizedStringKey {
        #if os(macOS)
        "This choice stays on this Mac. A project you turn off leaves it: its recordings, audio, search entries, and key are removed here once another device keeps a copy, and nothing is deleted anywhere else. With exactly one project chosen, new recordings go into it."
        #else
        "This choice stays on this device. A project you turn off leaves it: its recordings, audio, search entries, and key are removed here once another device keeps a copy, and nothing is deleted anywhere else. With exactly one project chosen, new recordings go into it."
        #endif
    }

    private var modeBinding: Binding<ProjectSelection.Mode> {
        Binding(
            get: { library.projectSelection.mode },
            set: { mode in
                var selection = library.projectSelection
                selection.mode = mode
                select(selection)
            }
        )
    }

    private func scopeBinding(_ scope: ProjectScope) -> Binding<Bool> {
        Binding(
            get: { library.projectSelection.scopes.contains(scope) },
            set: { isOn in
                var selection = library.projectSelection
                if isOn {
                    selection.scopes.insert(scope)
                } else {
                    selection.scopes.remove(scope)
                }
                select(selection)
            }
        )
    }

    private func select(_ selection: ProjectSelection) {
        library.setProjectSelection(selection)
        Task { await sync.syncIfEnabled() }
    }
}

private struct ScopeStorageText: View {
    let storage: ScopeStorage

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var text: LocalizedStringKey {
        #if os(macOS)
        switch storage {
        case .stored: "Stored on this Mac"
        case .waitingForKey: "Waiting for another device to share this project"
        case .leaving: "Removing from this Mac once another device keeps a copy"
        case .notStored: "Not stored on this Mac"
        }
        #else
        switch storage {
        case .stored: "Stored on this device"
        case .waitingForKey: "Waiting for another device to share this project"
        case .leaving: "Removing from this device once another device keeps a copy"
        case .notStored: "Not stored on this device"
        }
        #endif
    }
}
