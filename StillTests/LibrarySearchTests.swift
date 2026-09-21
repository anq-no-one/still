import Foundation
import Testing
@testable import Still

struct LibrarySearchTests {
    @Test
    func findsAPhraseInTheTranscriptAndPointsAtItsAudio() {
        let segments = words("We shipped the beta on Tuesday . Nothing else happened .")
        let recording = Recording(
            title: "Weekly sync",
            transcript: segments.plainText,
            segments: segments,
            duration: 300
        )

        let results = LibrarySearch.results(for: "beta on tuesday", in: [recording])

        #expect(results.count == 1)
        let result = results[0]
        #expect(result.match == .transcript)
        #expect(result.recordingID == recording.id)
        #expect(result.segmentID == segments[0].id)
        #expect(result.time == 0)
    }

    @Test
    func findsTitlesAndNotes() {
        let segments = words("We agreed to hire .")
        let recording = Recording(
            title: "Hiring plan",
            transcript: segments.plainText,
            segments: segments,
            note: Note(
                template: .meeting,
                decisions: [NoteItem(text: "We agreed to hire .", sourceSegmentIDs: [segments[0].id])],
                userText: "Ask finance about headcount"
            ),
            duration: 60
        )

        #expect(LibrarySearch.results(for: "hiring", in: [recording]).map(\.match) == [.title])
        #expect(LibrarySearch.results(for: "headcount", in: [recording]).map(\.match) == [.note])
    }

    @Test
    func ignoresCaseAndAccents() {
        let segments = words("Réunion avec Zoé .")
        let recording = Recording(title: "Call", transcript: segments.plainText, segments: segments, duration: 60)

        #expect(!LibrarySearch.results(for: "reunion avec zoe", in: [recording]).isEmpty)
    }

    @Test
    func aDeletedRecordingLeavesNoResults() {
        let segments = words("Secret plan .")
        let recording = Recording(title: "Call", transcript: segments.plainText, segments: segments, duration: 60)

        #expect(!LibrarySearch.results(for: "secret", in: [recording]).isEmpty)
        #expect(LibrarySearch.results(for: "secret", in: []).isEmpty)
    }

    @Test
    func aOneLetterQueryMatchesNothing() {
        let recording = Recording(title: "Anything", transcript: "a", duration: 5)

        #expect(LibrarySearch.results(for: "a", in: [recording]).isEmpty)
    }

    @Test
    func searchesACorrectedTranscript() {
        var segments = words("Meeting with Ana .")
        segments[2].correction = "Anna"
        let recording = Recording(
            title: "Call",
            transcript: segments.plainText,
            segments: segments,
            duration: 60
        )

        #expect(!LibrarySearch.results(for: "Anna", in: [recording]).isEmpty)
    }
}
