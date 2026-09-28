import SwiftUI

extension Library {
    @MainActor
    var nextUnusedProjectColor: ProjectColor {
        let used = Set(projects.map(\.color))
        return ProjectColor.allCases.first { !used.contains($0) } ?? .blue
    }

    @MainActor
    @discardableResult
    func createProject(named name: String) throws -> Project {
        try createProject(named: name, color: nextUnusedProjectColor)
    }
}

struct ProjectCreationField: View {
    let create: (String) throws -> Void

    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("New Project", text: $name)
                    .onSubmit(submit)
                Button("Add", systemImage: "plus", action: submit)
                    .disabled(trimmedName.isEmpty)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        do {
            try create(trimmedName)
            name = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
