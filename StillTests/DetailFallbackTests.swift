import Foundation
import Testing
@testable import Still

struct DetailFallbackTests {
    @Test
    func nothingSelectedShowsTheLatestRecording() {
        let recordings = [sample(title: "Latest"), sample(title: "Older")]

        #expect(DetailFallback.recording(selected: nil, recordings: recordings)?.title == "Latest")
    }

    @Test
    func explicitSelectionWinsOverLatest() {
        let recordings = [sample(title: "Latest"), sample(title: "Older")]

        let match = DetailFallback.recording(selected: recordings[1].id, recordings: recordings)

        #expect(match?.title == "Older")
    }

    @Test
    func staleSelectionFallsBackToLatest() {
        let recordings = [sample(title: "Latest")]

        #expect(DetailFallback.recording(selected: UUID(), recordings: recordings)?.title == "Latest")
    }

    @Test
    func emptyLibraryShowsNothing() {
        #expect(DetailFallback.recording(selected: nil, recordings: []) == nil)
    }

    private func sample(title: String) -> Recording {
        Recording(title: title, transcript: "", duration: 60)
    }
}
