import SwiftUI

struct ProjectTasksView: View {
    enum Page: Hashable {
        case tasks
        case decisions
    }

    let library: Library
    let projects: [Project]
    let open: (UUID, TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var page = Page.tasks

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $page) {
                        Text("Tasks").tag(Page.tasks)
                        Text("Decisions").tag(Page.decisions)
                    }
                    .pickerStyle(.segmented)

                    if projects.count > 1 {
                        Picker("Project", selection: $projectID) {
                            ForEach(projects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }
                    }
                }

                switch page {
                case .tasks: taskRows
                case .decisions: decisionSections
                }
            }
            .overlay {
                emptyState
            }
            .navigationTitle(project?.name ?? String(localized: "Tasks"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .stillSheetWidth(mac: 460, minHeight: 360)
        .onAppear {
            if projectID == nil { projectID = projects.first?.id }
        }
    }

    private var taskRows: some View {
        ForEach(tasks) { task in
            sourceButton(task, hint: "Opens the recording where this task was agreed") {
                Text(task.item.text)
                HStack(spacing: 10) {
                    if let owner = task.item.owner {
                        Label(owner, systemImage: "person")
                    }
                    if let due = task.item.due {
                        Label(due, systemImage: "calendar")
                    }
                    Text("\(task.recordingTitle) at \(task.time.recordingDurationText)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var decisionSections: some View {
        ForEach(threads) { thread in
            Section {
                sourceButton(thread.current, hint: "Opens the recording where this was decided") {
                    Text(thread.current.item.text)
                    SourceLine(source: thread.current)
                }
                ForEach(thread.earlier) { earlier in
                    sourceButton(earlier, hint: "Opens the recording where the earlier decision was made") {
                        Label {
                            Text(earlier.item.text)
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .foregroundStyle(.secondary)
                        SourceLine(source: earlier)
                    }
                    .padding(.leading, 12)
                }
            } header: {
                if thread.hasChanged {
                    Text("Changed")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch page {
        case .tasks where tasks.isEmpty:
            ContentUnavailableView(
                "No Accepted Tasks",
                systemImage: "checklist",
                description: Text("Tasks you accept in a recording appear here with their source.")
            )
        case .decisions where threads.isEmpty:
            ContentUnavailableView(
                "No Decisions Yet",
                systemImage: "signpost.right.and.left",
                description: Text("Decisions from this project's recordings appear here, with earlier ones kept beside the current one.")
            )
        case .tasks, .decisions:
            EmptyView()
        }
    }

    private func sourceButton(
        _ source: SourcedItem,
        hint: LocalizedStringKey,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button {
            dismiss()
            open(source.recordingID, source.time)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                label()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }

    private var project: Project? {
        projects.first { $0.id == projectID }
    }

    private var tasks: [SourcedItem] {
        projectID.map { library.acceptedTasks(inProject: $0) } ?? []
    }

    private var threads: [DecisionThread] {
        projectID.map { library.projectHistory($0).threads } ?? []
    }
}
