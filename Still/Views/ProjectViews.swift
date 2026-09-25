import SwiftUI

extension ProjectColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .mint: "Mint"
        case .teal: "Teal"
        case .cyan: "Cyan"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .brown: "Brown"
        case .gray: "Gray"
        }
    }
}

struct ProjectBadge: View {
    let project: Project

    var body: some View {
        Label {
            Text(project.name)
                .lineLimit(1)
        } icon: {
            ProjectDot(color: project.color)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Project \(project.name)"))
    }
}

struct ProjectDot: View {
    let color: ProjectColor

    var body: some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(color.color)
            .imageScale(.small)
            .accessibilityHidden(true)
    }
}

/// Buttons that move recordings, shared by the context menu and the detail
/// toolbar so both offer the same choices.
struct ProjectAssignmentButtons: View {
    let projects: [Project]
    let current: UUID?
    let assign: (UUID?) -> Void

    var body: some View {
        Button {
            assign(nil)
        } label: {
            Label("No Project", systemImage: current == nil ? "checkmark" : "circle.dashed")
        }

        if !projects.isEmpty {
            Divider()
        }

        ForEach(projects) { project in
            Button {
                assign(project.id)
            } label: {
                Label {
                    Text(project.name)
                } icon: {
                    Image(systemName: current == project.id ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(project.color.color)
                }
            }
        }
    }
}

struct ProjectConfirmationBar: View {
    let suggested: Project?
    let projects: [Project]
    let confirm: () -> Void
    let assign: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Confirm the Project", systemImage: "questionmark.folder")
                .font(.headline)
            Text("This recording stays on this device until you confirm its project. Then it syncs to your other devices.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Menu {
                    ProjectAssignmentButtons(projects: projects, current: suggested?.id, assign: assign)
                } label: {
                    if let suggested {
                        ProjectBadge(project: suggested)
                    } else {
                        Text("No Project")
                    }
                }
                .fixedSize()
                .accessibilityLabel(Text("Change Project"))

                Spacer()

                Button("Confirm", action: confirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    }
}

struct UnconfirmedProjectBadge: View {
    let suggested: Project?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "folder.badge.questionmark")
                .accessibilityHidden(true)
            Text(suggested.map { "\($0.name)?" } ?? String(localized: "Project?"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Project not confirmed. Not syncing yet."))
    }
}
