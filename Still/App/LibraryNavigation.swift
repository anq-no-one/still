import Observation

@MainActor
@Observable
final class LibraryNavigation {
    var selection: Recording.ID?
    var isChoosingAudioFile = false
}
