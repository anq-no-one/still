import Foundation

struct TileObservation: Equatable, Sendable {
    let offset: TimeInterval
    let names: [String]
}

protocol TileTextRecognizer: Sendable {
    func recognizeNames(in png: Data) async throws -> [String]
}

enum TileCueBuilder {
    static let minimumFrames = 2
    static let maximumGap: TimeInterval = 45

    static func cues(from observations: [TileObservation], endingAt end: TimeInterval) -> [SpeakerCue] {
        var open: [String: (name: String, start: TimeInterval, frames: Int, last: TimeInterval)] = [:]
        var finished: [SpeakerCue] = []
        for observation in observations.sorted(by: { $0.offset < $1.offset }) {
            let present = Set(observation.names.map(VoiceProfiles.key(for:)).filter { !$0.isEmpty })
            for key in open.keys where !present.contains(key) {
                if observation.offset - (open[key]?.last ?? 0) > maximumGap {
                    if let run = open.removeValue(forKey: key), run.frames >= minimumFrames {
                        finished.append(SpeakerCue(name: run.name, start: run.start, end: max(run.start, run.last)))
                    }
                }
            }
            for name in observation.names {
                let key = VoiceProfiles.key(for: name)
                guard !key.isEmpty else { continue }
                if var run = open[key] {
                    run.frames += 1
                    run.last = observation.offset
                    open[key] = run
                } else {
                    open[key] = (name, observation.offset, 1, observation.offset)
                }
            }
        }
        for (_, run) in open where run.frames >= minimumFrames {
            finished.append(SpeakerCue(name: run.name, start: run.start, end: max(run.start, end)))
        }
        return finished.sorted { ($0.start, $0.name) < ($1.start, $1.name) }
    }
}

#if os(macOS)
import Vision

struct VisionTileTextRecognizer: TileTextRecognizer {
    static let maximumLineLength = 48

    func recognizeNames(in png: Data) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation in
                    try? observation.topCandidates(1).first?.string
                }
                continuation.resume(returning: Self.clean(lines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(data: png, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func clean(_ lines: [String]) -> [String] {
        var kept: [String] = []
        var seen = Set<String>()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maximumLineLength, seen.insert(VoiceProfiles.key(for: trimmed)).inserted else { continue }
            kept.append(trimmed)
        }
        return kept
    }
}
#endif
