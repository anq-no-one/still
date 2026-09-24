import Foundation

protocol RecordingVisibility: Sendable {
    func isVisible(_ recording: Recording) -> Bool
}

/// Which projects this device shows. It stays on the device and never syncs,
/// so each Mac can keep to its own work while the iPhone sees everything.
struct ProjectSelection: RecordingVisibility, Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case all
        case only
        case except
    }

    var mode: Mode
    var scopes: Set<ProjectScope>

    init(mode: Mode = .all, scopes: Set<ProjectScope> = []) {
        self.mode = mode
        self.scopes = scopes
    }

    static let all = ProjectSelection()

    func includes(_ scope: ProjectScope) -> Bool {
        switch mode {
        case .all: true
        case .only: scopes.contains(scope)
        case .except: !scopes.contains(scope)
        }
    }

    func isVisible(_ recording: Recording) -> Bool {
        includes(recording.projectScope)
    }

    var soleProjectID: UUID? {
        guard mode == .only, scopes.count == 1, case .project(let id)? = scopes.first else { return nil }
        return id
    }
}
