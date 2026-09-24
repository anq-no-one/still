import Foundation
import Observation

@MainActor
@Observable
final class LibraryNavigation {
    var selection: Recording.ID?
    var isChoosingMediaFile = false
    var handedOverFile: URL?

    func handOver(_ url: URL) {
        guard url.isFileURL else { return }
        handedOverFile = url
    }
}
