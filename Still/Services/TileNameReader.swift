import Foundation

struct TileObservation: Equatable, Sendable {
    let offset: TimeInterval
    let names: [String]
    var activeSpeakerNames: [String] = []
}

protocol TileTextRecognizer: Sendable {
    func recognizeNames(in png: Data) async throws -> [String]
}

enum TileCueBuilder {
    static let minimumFrames = 2
    static let maximumGap: TimeInterval = 1.5

    private struct Run {
        var name: String
        var start: TimeInterval
        var frames: Int
        var last: TimeInterval
    }

    static func cues(from observations: [TileObservation], endingAt end: TimeInterval) -> [SpeakerCue] {
        var open: [String: Run] = [:]
        var finished: [SpeakerCue] = []
        for observation in observations.sorted(by: { $0.offset < $1.offset }) {
            let present = Set(observation.activeSpeakerNames.map(VoiceProfiles.key(for:)).filter { !$0.isEmpty })
            for key in Array(open.keys) {
                guard let run = open[key] else { continue }
                if !present.contains(key) || observation.offset - run.last > maximumGap {
                    open.removeValue(forKey: key)
                    if run.frames >= minimumFrames {
                        finished.append(SpeakerCue(name: run.name, start: run.start, end: min(observation.offset, run.last + maximumGap)))
                    }
                }
            }
            for name in observation.activeSpeakerNames {
                let key = VoiceProfiles.key(for: name)
                guard !key.isEmpty else { continue }
                if open[key] != nil {
                    open[key]?.frames += 1
                    open[key]?.last = observation.offset
                } else {
                    open[key] = Run(name: name, start: observation.offset, frames: 1, last: observation.offset)
                }
            }
        }
        for run in open.values where run.frames >= minimumFrames {
            finished.append(SpeakerCue(name: run.name, start: run.start, end: max(run.start, min(end, run.last + maximumGap))))
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
