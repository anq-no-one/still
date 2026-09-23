import Foundation
import Testing
@testable import Still

private final class FakeEmbeddingEngine: EmbeddingEngine {
    private let vectors: [String: [Float]]

    init(_ vectors: [String: [Float]]) {
        self.vectors = vectors
    }

    func embed(_ text: String) -> [Float]? {
        vectors[text]
    }
}

private func segment(_ text: String, start: TimeInterval = 0) -> TranscriptSegment {
    TranscriptSegment(start: start, end: start + 1, text: text, language: "en", confidence: 0.9)
}

struct SemanticIndexRankingTests {
    @Test
    func semanticFindsAParaphraseExactSearchMisses() {
        let deployed = segment("We shipped the update to every region", start: 10)
        let recording = Recording(
            title: "Rollout",
            transcript: deployed.text,
            segments: [deployed],
            duration: 60
        )
        let engine = FakeEmbeddingEngine([
            deployed.displayText: [1, 0],
            "launched the release worldwide": [0.95, Float(1 - 0.95 * 0.95).squareRoot()]
        ])
        let index = SemanticIndex(engine: engine)
        index.update(recording)

        let results = LibrarySearch.results(
            for: "launched the release worldwide",
            in: [recording],
            semanticIndex: index
        )

        #expect(results.count == 1)
        #expect(results[0].match == .transcript)
        #expect(results[0].segmentID == deployed.id)
        #expect(results[0].time == 10)
    }

    @Test
    func exactMatchesAreNeverDuplicatedAsSemanticHits() {
        let update = segment("We shipped the beta on Tuesday")
        let recording = Recording(title: "Update", transcript: update.text, segments: [update], duration: 60)
        let engine = FakeEmbeddingEngine([update.displayText: [1, 0], "beta": [1, 0]])
        let index = SemanticIndex(engine: engine)
        index.update(recording)

        let results = LibrarySearch.results(for: "beta", in: [recording], semanticIndex: index)

        #expect(results.count == 1)
        #expect(results[0].match == .transcript)
    }

    @Test
    func hitsBelowTheThresholdAreDropped() {
        let unrelated = segment("The kitchen sink is leaking again")
        let recording = Recording(title: "Facilities", transcript: unrelated.text, segments: [unrelated], duration: 60)
        let engine = FakeEmbeddingEngine([unrelated.displayText: [1, 0], "quarterly revenue": [0, 1]])
        let index = SemanticIndex(engine: engine)
        index.update(recording)

        let results = LibrarySearch.results(
            for: "quarterly revenue",
            in: [recording],
            semanticIndex: index,
            semanticThreshold: 0.6
        )

        #expect(results.isEmpty)
    }

    @Test
    func fallsBackToExactSearchWhenEmbeddingsAreUnavailable() {
        let update = segment("We shipped the beta on Tuesday")
        let recording = Recording(title: "Update", transcript: update.text, segments: [update], duration: 60)
        let index = SemanticIndex(engine: nil)
        index.update(recording)

        let withSemantic = LibrarySearch.results(for: "beta", in: [recording], semanticIndex: index)
        let exactOnly = LibrarySearch.results(for: "beta", in: [recording])

        #expect(withSemantic.map(\.snippet) == exactOnly.map(\.snippet))
        #expect(withSemantic.map(\.match) == exactOnly.map(\.match))
        #expect(!index.isAvailable)
    }
}

struct SemanticIndexUpdateTests {
    @Test
    func rebuildsSemanticEntriesAfterATranscriptEdit() {
        let original = segment("We shipped the beta on Tuesday")
        var recording = Recording(title: "Update", transcript: original.text, segments: [original], duration: 60)
        let engine = FakeEmbeddingEngine([
            original.displayText: [1, 0],
            "launched the release worldwide": [0.95, Float(1 - 0.95 * 0.95).squareRoot()],
            "a quiet weekend at the lake": [0, 1]
        ])
        let index = SemanticIndex(engine: engine)
        index.update(recording)

        #expect(!index.matches(for: "launched the release worldwide", threshold: 0.6).isEmpty)

        var edited = original
        edited.correction = "a quiet weekend at the lake"
        recording.segments = [edited]
        recording.transcript = edited.correction ?? edited.text
        index.update(recording)

        #expect(index.matches(for: "launched the release worldwide", threshold: 0.6).isEmpty)
        #expect(!index.matches(for: "a quiet weekend at the lake", threshold: 0.6).isEmpty)
    }

    @Test
    func removesEntriesForADeletedRecording() {
        let update = segment("We shipped the beta on Tuesday")
        var recording = Recording(title: "Update", transcript: update.text, segments: [update], duration: 60)
        let engine = FakeEmbeddingEngine([update.displayText: [1, 0]])
        let index = SemanticIndex(engine: engine)
        index.update(recording)

        #expect(!index.matches(for: update.displayText, threshold: 0.99).isEmpty)

        recording.deletedAt = .now
        index.update(recording)

        #expect(index.matches(for: update.displayText, threshold: 0.99).isEmpty)
    }

    @Test
    func rebuildSkipsAlreadyDeletedRecordings() {
        let update = segment("We shipped the beta on Tuesday")
        var recording = Recording(title: "Update", transcript: update.text, segments: [update], duration: 60)
        recording.deletedAt = .now
        let engine = FakeEmbeddingEngine([update.displayText: [1, 0]])
        let index = SemanticIndex(engine: engine)

        index.rebuild([recording])

        #expect(index.matches(for: update.displayText, threshold: 0.99).isEmpty)
    }
}
