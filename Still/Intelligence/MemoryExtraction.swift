import Foundation
import Observation

@MainActor
@Observable
final class MemoryExtraction {
    private let library: Library
    private let preferred: @MainActor () -> Extractor?
    private let fallback: Extractor
    private let validator: ProvenanceValidator
    private let characterBudget: Int
    private let now: () -> Date
    private var worker: Task<Void, Never>?
    private var needsAnotherPass = false

    private(set) var processingIDs: Set<UUID> = []
    private(set) var lastFailure: String?

    init(
        library: Library,
        preferred: @escaping @MainActor () -> Extractor? = { nil },
        fallback: Extractor = ExtractiveExtractor(),
        validator: ProvenanceValidator = ProvenanceValidator(),
        characterBudget: Int = ExtractionWindows.characterBudget,
        now: @escaping () -> Date = { .now }
    ) {
        self.library = library
        self.preferred = preferred
        self.fallback = fallback
        self.validator = validator
        self.characterBudget = characterBudget
        self.now = now
    }

    var pendingIDs: [UUID] {
        guard library.state == .unlocked else { return [] }
        return library.recordings.filter(\.needsExtraction).map(\.id)
    }

    func start() {
        withObservationTracking {
            _ = pendingIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.start()
            }
        }
        schedule()
    }

    func schedule() {
        guard worker == nil else {
            needsAnotherPass = true
            return
        }

        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    func processPending() async {
        for id in pendingIDs {
            guard !Task.isCancelled else { return }
            await process(id)
        }
    }

    func reprocess(_ recordingID: UUID) async {
        await process(recordingID, restarting: true)
    }

    func process(_ recordingID: UUID, restarting: Bool = false) async {
        guard let recording = library.recordings.first(where: { $0.id == recordingID }),
              recording.isReadyForExtraction
        else { return }

        processingIDs.insert(recordingID)
        defer { processingIDs.remove(recordingID) }

        do {
            try await AITrace.$recordingID.withValue(recordingID) {
                try await AITrace.$stage.withValue("memory") {
                    try await Perf.trace("memory.recording", ["recordingID": recordingID.uuidString, "segments": String(recording.segments.count)]) {
                        try await extract(recording, restarting: restarting)
                    }
                }
            }
            lastFailure = nil
        } catch is CancellationError {
            return
        } catch {
            DevLog.error("memory.failed", error, ["recordingID": recordingID.uuidString])
            lastFailure = error.localizedDescription
        }
    }

    private func drain() async {
        repeat {
            needsAnotherPass = false
            await processPending()
        } while needsAnotherPass && !Task.isCancelled
        worker = nil
    }

    private func extract(_ recording: Recording, restarting: Bool) async throws {
        let segments = ExtractionSegment.segments(of: recording)
        let windows = ExtractionWindows.windows(of: segments, characterBudget: characterBudget)
        let fingerprint = ExtractionRun.fingerprint(of: recording.segments)

        var run = recording.memory?.run
        if restarting || run?.fingerprint != fingerprint {
            let fresh = ExtractionRun(fingerprint: fingerprint, startedAt: now(), totalChunks: windows.count)
            var started = recording
            started.memory = (recording.memory ?? RecordingMemory()).beginning(fresh)
            try library.save(started)
            run = fresh
        }
        guard let run, !run.isComplete else { return }

        let language = recording.segments.lazy.compactMap(\.language).first
        for index in run.completedChunks..<windows.count {
            try Task.checkCancellation()
            let chunk = Perf.begin("memory.chunk")
            let (candidates, extractorID) = try await candidates(in: windows[index], language: language)
            Perf.end(chunk, [
                "recordingID": recording.id.uuidString,
                "chunk": "\(index + 1)/\(windows.count)",
                "extractor": extractorID,
                "segments": String(windows[index].count),
                "candidates": String(candidates.count),
            ])
            try Task.checkCancellation()

            guard var latest = library.recordings.first(where: { $0.id == recording.id }),
                  let memory = latest.memory,
                  run.isSameRun(as: memory.run),
                  latest.isReadyForExtraction
            else { return }

            let outcome = Perf.measure("memory.validate") {
                validator.validate(candidates, against: latest.segments, speakers: latest.speakers)
            }
            AITrace.record("memory.validated", [
                "chunk": "\(index + 1)/\(windows.count)",
                "extractor": extractorID,
                "candidates": candidates.map { "\($0.kind.rawValue): \($0.text) [cites \($0.citedSegmentIDs.count)] owner=\($0.owner ?? "-") due=\($0.due ?? "-")" }.joined(separator: "\n"),
                "kept": outcome.items.map { "\($0.kind.rawValue): \($0.extractedText)" }.joined(separator: "\n"),
                "withheld": String(outcome.withheld),
            ])
            latest.memory = memory.absorbing(outcome.items, withheld: outcome.withheld, completedChunks: index + 1)
            try library.save(latest)
        }
    }

    private func candidates(in window: [ExtractionSegment], language: String?) async throws -> ([ExtractionCandidate], String) {
        if let preferred = preferred() {
            do {
                return (try await preferred.candidates(from: window, language: language), preferred.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AITrace.record("memory.modelFailed", ["extractor": preferred.id, "error": String(describing: error)])
                return (try await fallback.candidates(from: window, language: language), "\(fallback.id) (after \(preferred.id) failed)")
            }
        }
        return (try await fallback.candidates(from: window, language: language), fallback.id)
    }
}
