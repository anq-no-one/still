import Foundation
import Observation

@MainActor
@Observable
final class LibraryNavigation {
    var selection: Recording.ID?
    var isChoosingMediaFile = false
    var handedOverFile: URL?
    private var start: SourceTime?

    var startTime: TimeInterval? {
        guard let start, start.recordingID == selection else { return nil }
        return start.time
    }

    func open(_ recordingID: Recording.ID, at time: TimeInterval?) {
        selection = recordingID
        start = time.map { SourceTime(recordingID: recordingID, time: $0) }
    }

    func handOver(_ url: URL) {
        guard url.isFileURL else { return }
        handedOverFile = url
    }
}

private struct SourceTime {
    let recordingID: Recording.ID
    let time: TimeInterval
}
