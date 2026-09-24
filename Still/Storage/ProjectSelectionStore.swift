import Foundation

protocol ProjectSelectionStore {
    func load() -> ProjectSelection
    func save(_ selection: ProjectSelection)
}

struct UserDefaultsProjectSelectionStore: ProjectSelectionStore {
    private let key = "still.projects.deviceSelection"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ProjectSelection {
        defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(ProjectSelection.self, from: $0) } ?? .all
    }

    func save(_ selection: ProjectSelection) {
        defaults.set(try? JSONEncoder().encode(selection), forKey: key)
    }
}

final class MemoryProjectSelectionStore: ProjectSelectionStore {
    private var selection: ProjectSelection

    init(_ selection: ProjectSelection = .all) {
        self.selection = selection
    }

    func load() -> ProjectSelection {
        selection
    }

    func save(_ selection: ProjectSelection) {
        self.selection = selection
    }
}
