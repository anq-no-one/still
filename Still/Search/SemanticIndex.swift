import Foundation
import Observation

@Observable
final class SemanticIndex {
    struct Match {
        let recordingID: UUID
        let segmentID: UUID
        let time: TimeInterval
        let text: String
        let score: Float
    }

    private struct Entry: Sendable {
        let segmentID: UUID
        let time: TimeInterval
        let text: String
        let vector: [Float]
    }

    private struct Input: Equatable, Sendable {
        let segmentID: UUID
        let time: TimeInterval
        let text: String

        init(_ segment: TranscriptSegment) {
            segmentID = segment.id
            time = segment.start
            text = segment.displayText
        }
    }

    @ObservationIgnored private var inputsByRecording: [UUID: [Input]] = [:]
    @ObservationIgnored private var pendingUpdates: [UUID: Task<Void, Never>] = [:]
    private let engine: EmbeddingEngine?
    private var entriesByRecording: [UUID: [Entry]] = [:]
    @ObservationIgnored private var removedDuringRebuild: Set<UUID> = []
    @ObservationIgnored private var isRebuilding = false

    init(engine: EmbeddingEngine?) {
        self.engine = engine
    }

    var isAvailable: Bool {
        engine != nil
    }

    func rebuild(_ recordings: [Recording]) {
        entriesByRecording.removeAll()
        inputsByRecording.removeAll()
        for task in pendingUpdates.values { task.cancel() }
        pendingUpdates.removeAll()
        for recording in recordings where !recording.isDeleted {
            update(recording)
        }
    }

    @MainActor
    @discardableResult
    func rebuildInBackground(_ recordings: [Recording]) -> Task<Void, Never> {
        guard let engine else { return Task {} }

        isRebuilding = true
        let live = recordings.filter { !$0.isDeleted }
        for recording in live where inputsByRecording[recording.id] == nil {
            inputsByRecording[recording.id] = recording.segments.map(Input.init)
        }
        return Task { @MainActor in
            let built = await Task.detached(priority: .utility) {
                Perf.measure("semantic.rebuild", ["recordings": String(live.count)]) {
                    Dictionary(uniqueKeysWithValues: live.map { ($0.id, Self.entries(for: $0, engine: engine)) })
                }
            }.value

            entriesByRecording = built
                .filter { !removedDuringRebuild.contains($0.key) }
                .merging(entriesByRecording) { _, updatedMeanwhile in updatedMeanwhile }
            removedDuringRebuild.removeAll()
            isRebuilding = false
        }
    }

    func update(_ recording: Recording) {
        guard !recording.isDeleted else {
            remove(recording.id)
            return
        }

        guard let engine else { return }
        let inputs = recording.segments.map(Input.init)
        guard inputsByRecording[recording.id] != inputs else { return }
        pendingUpdates.removeValue(forKey: recording.id)?.cancel()
        inputsByRecording[recording.id] = inputs

        entriesByRecording[recording.id] = Perf.measure("semantic.update", ["recordingID": recording.id.uuidString, "segments": String(recording.segments.count)]) {
            Self.entries(for: recording, engine: engine)
        }
    }

    @MainActor
    @discardableResult
    func updateInBackground(_ recording: Recording) -> Task<Void, Never> {
        guard !recording.isDeleted else {
            remove(recording.id)
            return Task {}
        }
        guard let engine else { return Task {} }
        let inputs = recording.segments.map(Input.init)
        guard inputsByRecording[recording.id] != inputs else {
            return pendingUpdates[recording.id] ?? Task {}
        }
        pendingUpdates.removeValue(forKey: recording.id)?.cancel()
        inputsByRecording[recording.id] = inputs
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let entries = await Task.detached(priority: .utility) {
                Perf.measure("semantic.update", ["recordingID": recording.id.uuidString, "segments": String(recording.segments.count)]) {
                    Self.entries(for: recording, engine: engine)
                }
            }.value
            guard !Task.isCancelled, inputsByRecording[recording.id] == inputs else { return }
            entriesByRecording[recording.id] = entries
            pendingUpdates.removeValue(forKey: recording.id)
        }
        pendingUpdates[recording.id] = task
        return task
    }

    func remove(_ recordingID: UUID) {
        inputsByRecording.removeValue(forKey: recordingID)
        pendingUpdates.removeValue(forKey: recordingID)?.cancel()
        entriesByRecording.removeValue(forKey: recordingID)
        if isRebuilding {
            removedDuringRebuild.insert(recordingID)
        }
    }

    private static func entries(for recording: Recording, engine: EmbeddingEngine) -> [Entry] {
        recording.segments.compactMap { segment in
            guard let vector = engine.embed(segment.displayText) else { return nil }
            return Entry(segmentID: segment.id, time: segment.start, text: segment.displayText, vector: vector)
        }
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
