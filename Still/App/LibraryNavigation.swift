import Observation

@MainActor
@Observable
final class LibraryNavigation {
    var selection: Recording.ID?
}
