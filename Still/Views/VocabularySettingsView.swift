import SwiftUI

struct VocabularySettingsView: View {
    let library: Library

    @State private var editedProject: Project?

    var body: some View {
        Form {
            Section {
                if library.activeProjects.isEmpty {
                    ProjectCreationField(create: { name in
                        _ = try library.createProject(named: name)
                    })
                }
                ForEach(library.activeProjects) { project in
                    LabeledContent {
                        Button("Edit") { editedProject = project }
                            .accessibilityLabel(Text("Edit Vocabulary for \(project.name)"))
                    } label: {
                        ProjectBadge(project: project)
                        Text("\(library.vocabulary(forProject: project.id).activeTerms.count) terms")
                    }
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("Each project keeps its own spellings of names and terms. Still applies them to new recordings in that project.")
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Vocabulary")
        .sheet(item: $editedProject) { project in
            VocabularyEditorView(library: library, project: project)
        }
    }
}
