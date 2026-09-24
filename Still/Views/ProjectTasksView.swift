import SwiftUI

struct ProjectTasksView: View {
    let library: Library
    let projects: [Project]
    let open: (UUID, TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?

    var body: some View {
        NavigationStack {
            List {
                if projects.count > 1 {
                    Picker("Project", selection: $projectID) {
                        ForEach(projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                }

                ForEach(tasks) { task in
                    Button {
                        dismiss()
                        open(task.recordingID, task.item.sourceStart)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.item.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 10) {
                                if let owner = task.item.owner {
                                    Label(owner, systemImage: "person")
                                }
                                if let due = task.item.due {
                                    Label(due, systemImage: "calendar")
                                }
                                Text("\(task.recordingTitle) at \(task.item.sourceStart.recordingDurationText)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the recording where this task was agreed")
                }
            }
            .overlay {
                if tasks.isEmpty {
                    ContentUnavailableView(
                        "No Accepted Tasks",
                        systemImage: "checklist",
                        description: Text("Tasks you accept in a recording appear here with their source.")
                    )
                }
            }
            .navigationTitle(project?.name ?? String(localized: "Tasks"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .stillSheetWidth(mac: 420, minHeight: 360)
        .onAppear {
            if projectID == nil { projectID = projects.first?.id }
        }
    }

    private var project: Project? {
        projects.first { $0.id == projectID }
    }

    private var tasks: [ProjectTask] {
        projectID.map { library.acceptedTasks(inProject: $0) } ?? []
    }
}
