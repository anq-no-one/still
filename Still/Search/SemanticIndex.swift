import Foundation

final class SemanticIndex {
    struct Match {
        let recordingID: UUID
        let segmentID: UUID
        let time: TimeInterval
        let text: String
        let score: Float
    }

    private struct Entry {
        let segmentID: UUID
        let time: TimeInterval
        let text: String
        let vector: [Float]
    }

    private let engine: EmbeddingEngine?
    private var entriesByRecording: [UUID: [Entry]] = [:]

    init(engine: EmbeddingEngine?) {
        self.engine = engine
    }

    var isAvailable: Bool {
        engine != nil
    }

    func rebuild(_ recordings: [Recording]) {
        entriesByRecording.removeAll()
        for recording in recordings where !recording.isDeleted {
            update(recording)
        }
    }

    func update(_ recording: Recording) {
        guard !recording.isDeleted else {
            remove(recording.id)
            return
        }

        guard let engine else { return }

        entriesByRecording[recording.id] = recording.segments.compactMap { segment in
            guard let vector = engine.embed(segment.displayText) else { return nil }
            return Entry(segmentID: segment.id, time: segment.start, text: segment.displayText, vector: vector)
        }
    }

    func remove(_ recordingID: UUID) {
        entriesByRecording.removeValue(forKey: recordingID)
    }

    func matches(for query: String, threshold: Float) -> [Match] {
        guard let engine, let queryVector = engine.embed(query) else { return [] }

        return entriesByRecording.flatMap { recordingID, entries in
            entries.compactMap { entry -> Match? in
                let score = cosineSimilarity(entry.vector, queryVector)
                guard score >= threshold else { return nil }
                return Match(recordingID: recordingID, segmentID: entry.segmentID, time: entry.time, text: entry.text, score: score)
            }
        }
    }
}

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return 0 }
    var dot: Float = 0
    for index in 0..<a.count {
        dot += a[index] * b[index]
    }
    return dot
}
