import SwiftUI

struct DashboardView: View {
    let dashboard: Dashboard
    let library: Library
    let open: (UUID, TimeInterval?) -> Void

    var body: some View {
        List {
            DashboardSections(dashboard: dashboard, library: library, open: open)
        }
        .navigationTitle("Needs Attention")
    }
}

struct DashboardSections: View {
    let dashboard: Dashboard
    let library: Library
    let open: (UUID, TimeInterval?) -> Void

    var body: some View {
        if !dashboard.awaitingProject.isEmpty {
            Section("Awaiting a Project") {
                ForEach(dashboard.awaitingProject) { recording in
                    DashboardButton(hint: "Opens the recording so you can confirm its project") {
                        open(recording.id, nil)
                    } label: {
                        Text(recording.title)
                            .lineLimit(2)
                        HStack {
                            UnconfirmedProjectBadge(suggested: library.project(withID: recording.projectID))
                            Text(recording.createdAt, format: .dateTime.day().month().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }

        if !dashboard.proposedTasks.isEmpty {
            Section("Tasks to Review") {
                ForEach(dashboard.proposedTasks) { task in
                    DashboardButton(hint: "Opens the recording where this task was proposed") {
                        open(task.recordingID, task.time)
                    } label: {
                        Text(task.item.text)
                        SourceLine(source: task)
                    }
                }
            }
        }

        if !dashboard.changedDecisions.isEmpty {
            Section("Changed Decisions") {
                ForEach(dashboard.changedDecisions) { thread in
                    DashboardButton(hint: "Opens the recording where this decision changed") {
                        open(thread.current.recordingID, thread.current.time)
                    } label: {
                        Text(thread.current.item.text)
                        if let previous = thread.earlier.first {
                            Text("Before: \(previous.item.text)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        SourceLine(source: thread.current)
                    }
                }
            }
        }
    }
}

struct SourceLine: View {
    let source: SourcedItem

    var body: some View {
        HStack(spacing: 6) {
            Text(source.recordingDate, format: .dateTime.day().month().year())
            Text("\(source.recordingTitle) at \(source.time.recordingDurationText)")
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct DashboardButton<Label: View>: View {
    let hint: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                label()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }
}
