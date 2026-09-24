import SwiftUI

struct ProjectsSettingsView: View {
    let library: Library

    @State private var newName = ""
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                ForEach(library.projects) { project in
                    ProjectEditorRow(project: project, save: save)
                }

                HStack {
                    TextField("New Project", text: $newName)
                        .onSubmit(create)
                    Button("Add", systemImage: "plus", action: create)
                        .disabled(trimmedName.isEmpty)
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("Projects sync to your other devices, encrypted like your recordings.")
            }

            DeviceProjectSelectionSection(library: library)

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Projects")
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }

        let used = Set(library.projects.map(\.color))
        let color = ProjectColor.allCases.first { !used.contains($0) } ?? .blue
        do {
            try library.createProject(named: trimmedName, color: color)
            newName = ""
            failure = nil
        } catch {
            failure = error.localizedDescription
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

    @State private var name: String

    init(project: Project, save: @escaping (Project) -> Void) {
        self.project = project
        self.save = save
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
                            Image(systemName: "circle.fill")
                                .foregroundStyle(color.color)
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

    var body: some View {
        Section {
            Picker("Show", selection: modeBinding) {
                Text("All Projects").tag(ProjectSelection.Mode.all)
                Text("Only These Projects").tag(ProjectSelection.Mode.only)
                Text("All Except These").tag(ProjectSelection.Mode.except)
            }

            if library.projectSelection.mode != .all {
                Toggle(isOn: scopeBinding(.noProject)) {
                    Label("No Project", systemImage: "circle.dashed")
                }

                ForEach(library.projects) { project in
                    Toggle(isOn: scopeBinding(.project(project.id))) {
                        ProjectBadge(project: project)
                    }
                }
            }
        } header: {
            Text(deviceTitle)
        } footer: {
            Text("This choice stays on this device. Recordings outside it do not appear in the library, search, Siri, or the menu bar, and their audio is not downloaded here. With exactly one project chosen, new recordings go into it.")
        }
    }

    private var deviceTitle: LocalizedStringKey {
        #if os(macOS)
        "On This Mac"
        #else
        "On This Device"
        #endif
    }

    private var modeBinding: Binding<ProjectSelection.Mode> {
        Binding(
            get: { library.projectSelection.mode },
            set: { mode in
                var selection = library.projectSelection
                selection.mode = mode
                library.setProjectSelection(selection)
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
                library.setProjectSelection(selection)
            }
        )
    }
}
