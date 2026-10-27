import Foundation
import Synchronization
import Testing
@testable import Still

private final class CountingSemanticEngine: EmbeddingEngine {
    private let calls = Mutex(0)
    private let mainThreadCalls = Mutex(0)

    var count: Int { calls.withLock { $0 } }
    var mainCount: Int { mainThreadCalls.withLock { $0 } }

    func embed(_ text: String) -> [Float]? {
        calls.withLock { $0 += 1 }
        if Thread.isMainThread { mainThreadCalls.withLock { $0 += 1 } }
        return [1, 0]
    }
}

struct SemanticIndexEfficiencyTests {
    @Test
    func metadataChangesReuseTranscriptEmbeddings() {
        let segment = TranscriptSegment(start: 0, end: 1, text: "A stable transcript", language: "en", confidence: 1)
        var recording = Recording(title: "Before", transcript: segment.text, segments: [segment], duration: 1)
        let engine = CountingSemanticEngine()
        let index = SemanticIndex(engine: engine)
        index.update(recording)
        recording.title = "After"
        index.update(recording)
        #expect(engine.count == 1)
    }

    @Test @MainActor
    func transcriptEmbeddingRunsAwayFromTheMainThread() async {
        let segment = TranscriptSegment(start: 0, end: 1, text: "A stable transcript", language: "en", confidence: 1)
        let recording = Recording(title: "Meeting", transcript: segment.text, segments: [segment], duration: 1)
        let engine = CountingSemanticEngine()
        let index = SemanticIndex(engine: engine)
        await index.updateInBackground(recording).value
        #expect(engine.count == 1)
        #expect(engine.mainCount == 0)
        #expect(index.matches(for: segment.text, threshold: 0.5).count == 1)
    }

    @Test @MainActor
    func deletedRecordingCannotReturnFromAnOutstandingEmbedding() async {
        let segment = TranscriptSegment(start: 0, end: 1, text: "A stable transcript", language: "en", confidence: 1)
        let recording = Recording(title: "Meeting", transcript: segment.text, segments: [segment], duration: 1)
        let index = SemanticIndex(engine: CountingSemanticEngine())
        let update = index.updateInBackground(recording)
        index.remove(recording.id)
        await update.value
        #expect(index.matches(for: segment.text, threshold: 0.5).isEmpty)
    }

    @Test @MainActor
    func metadataChangesReuseAnOutstandingBackgroundEmbedding() async {
        let segment = TranscriptSegment(start: 0, end: 1, text: "A stable transcript", language: "en", confidence: 1)
        var recording = Recording(title: "Meeting", transcript: segment.text, segments: [segment], duration: 1)
        let engine = CountingSemanticEngine()
        let index = SemanticIndex(engine: engine)
        let first = index.updateInBackground(recording)
        recording.title = "Renamed"
        let second = index.updateInBackground(recording)
        await first.value
        await second.value
        #expect(engine.count == 1)
    }

    @Test @MainActor
    func metadataChangesAfterAFinishedBackgroundEmbeddingDoNotEmbedAgain() async {
        let segment = TranscriptSegment(start: 0, end: 1, text: "A stable transcript", language: "en", confidence: 1)
        var recording = Recording(title: "Meeting", transcript: segment.text, segments: [segment], duration: 1)
        let engine = CountingSemanticEngine()
        let index = SemanticIndex(engine: engine)
        await index.updateInBackground(recording).value
        recording.title = "Renamed"
        await index.updateInBackground(recording).value
        #expect(engine.count == 1)
    }
}
