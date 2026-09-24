import Foundation

struct Project: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    private(set) var stampedName: Stamped<String>
    private(set) var stampedColor: Stamped<ProjectColor>
    private(set) var stampedArchived: Stamped<Bool>

    init(id: UUID = UUID(), name: String, color: ProjectColor, createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
        stampedName = Stamped(value: name, stampedAt: createdAt)
        stampedColor = Stamped(value: color, stampedAt: createdAt)
        stampedArchived = Stamped(value: false, stampedAt: createdAt)
    }

    var name: String {
        stampedName.value
    }

    var color: ProjectColor {
        stampedColor.value
    }

    var isArchived: Bool {
        stampedArchived.value
    }

    var updatedAt: Date {
        max(stampedName.stampedAt, stampedColor.stampedAt, stampedArchived.stampedAt)
    }

    mutating func rename(to name: String, at date: Date = .now) {
        stampedName = Stamped(value: name, stampedAt: date)
    }

    mutating func recolor(to color: ProjectColor, at date: Date = .now) {
        stampedColor = Stamped(value: color, stampedAt: date)
    }

    mutating func setArchived(_ isArchived: Bool, at date: Date = .now) {
        stampedArchived = Stamped(value: isArchived, stampedAt: date)
    }

    /// Each field follows its own latest edit, so a rename on one device and a
    /// recolor on another both survive.
    static func merge(_ first: Project, _ second: Project) -> Project {
        guard first.id == second.id else { return first }

        var merged = first
        merged.stampedName = .latest(first.stampedName, second.stampedName)
        merged.stampedColor = .latest(first.stampedColor, second.stampedColor)
        merged.stampedArchived = .latest(first.stampedArchived, second.stampedArchived)
        return merged
    }
}

struct Stamped<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var value: Value
    var stampedAt: Date

    /// Equal stamps fall back to comparing the values, so every device picks
    /// the same winner whichever order the edits arrive in.
    static func latest(_ first: Stamped, _ second: Stamped) -> Stamped {
        if first.stampedAt != second.stampedAt {
            return first.stampedAt > second.stampedAt ? first : second
        }
        return String(describing: first.value) >= String(describing: second.value) ? first : second
    }
}

enum ProjectColor: String, Codable, CaseIterable, Sendable {
    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case cyan
    case blue
    case indigo
    case purple
    case pink
    case brown
    case gray
}

enum ProjectScope: Hashable, Codable, Sendable {
    case noProject
    case project(UUID)
}

enum ScopeStorage: Equatable, Sendable {
    case stored
    case waitingForKey
    case leaving
    case notStored
}

extension Recording {
    var projectScope: ProjectScope {
        projectID.map(ProjectScope.project) ?? .noProject
    }

    var isProjectConfirmed: Bool {
        projectAssignedAt != nil
    }

    mutating func assign(toProject projectID: UUID?, at date: Date = .now) {
        self.projectID = projectID
        projectAssignedAt = date
        updatedAt = max(updatedAt, date)
    }

    /// The project follows the later assignment, whichever copy carries it, so
    /// a stale copy saved after a move cannot undo the move.
    func keepingLatestProject(of other: Recording) -> Recording {
        let mine = projectAssignedAt ?? .distantPast
        let theirs = other.projectAssignedAt ?? .distantPast
        let otherWins = theirs > mine
            || (theirs == mine && (other.projectID?.uuidString ?? "") > (projectID?.uuidString ?? ""))
        guard otherWins else { return self }

        var result = self
        result.projectID = other.projectID
        result.projectAssignedAt = other.projectAssignedAt
        return result
    }
}
