import Foundation

/// System surfaces reach Still through this one handle. It holds no content of
/// its own, so an intent can only see what an unlocked Library would already
/// show in the app.
@MainActor
final class StillIntentEnvironment {
    static let shared = StillIntentEnvironment()

    private(set) var library: Library?
    private(set) var coordinator: RecordingCoordinator?

    private init() {}

    func install(library: Library, coordinator: RecordingCoordinator) {
        self.library = library
        self.coordinator = coordinator
    }

    /// Siri never bypasses the lock. A locked Library answers with a request to
    /// authenticate in Still rather than with its contents.
    func unlockedLibrary() throws -> Library {
        guard let library else { throw StillIntentError.unavailable }
        guard library.state == .unlocked else { throw StillIntentError.locked }
        return library
    }
}

enum StillIntentError: LocalizedError, Equatable {
    case locked
    case unavailable
    case noRecordings

    var errorDescription: String? {
        switch self {
        case .locked:
            "Open Still and unlock your Library first."
        case .unavailable:
            "Still is not ready yet. Open the app and try again."
        case .noRecordings:
            "There is no recording that matches."
        }
    }
}
