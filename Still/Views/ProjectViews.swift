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
        color.swatch()
            .accessibilityHidden(true)
    }
}

extension ProjectColor {
    /// Menus on macOS draw symbol images as black templates, so the swatch is
    /// a drawn bitmap that keeps its color everywhere.
    func swatch(selected: Bool = false) -> Image {
        #if os(macOS)
        Image(nsImage: ProjectSwatch.platformImage(self, selected: selected)).renderingMode(.original)
        #else
        Image(uiImage: ProjectSwatch.platformImage(self, selected: selected)).renderingMode(.original)
        #endif
    }
}

enum ProjectSwatch {
    static let side: CGFloat = 12

    private static func dotRect(in rect: CGRect) -> CGRect {
        rect.insetBy(dx: side * 0.32, dy: side * 0.32)
    }

    #if os(macOS)
    static func platformImage(_ color: ProjectColor, selected: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(color.color).setFill()
            NSBezierPath(ovalIn: rect).fill()
            if selected {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: dotRect(in: rect)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
    #else
    static func platformImage(_ color: ProjectColor, selected: Bool = false) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            UIColor(color.color).setFill()
            context.cgContext.fillEllipse(in: rect)
            if selected {
                UIColor.white.setFill()
                context.cgContext.fillEllipse(in: dotRect(in: rect))
            }
        }
        .withRenderingMode(.alwaysOriginal)
    }
    #endif
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
                    project.color.swatch(selected: current == project.id)
                }
            }
            .accessibilityAddTraits(current == project.id ? .isSelected : [])
        }
    }
}

struct ProjectConfirmationBar: View {
    let suggested: Project?
    let projects: [Project]
    let confirm: () -> Void
    let assign: (UUID?) -> Void
    let create: (String) throws -> Void

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

            ProjectCreationField(create: create)
        }
        .padding()
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    }
}

struct UnconfirmedProjectBadge: View {
    let suggested: Project?

    var body: some View {
        if let suggested {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ProjectDot(color: suggested.color)
                Text("\(suggested.name)?")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Project not confirmed. Not syncing yet."))
        } else {
            Text("No Project")
                .foregroundStyle(.secondary.opacity(0.6))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("No project. Not syncing yet."))
        }
    }
}
