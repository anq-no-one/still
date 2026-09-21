import Foundation

/// Word error rate over normalized tokens: the edit distance between what was
/// said and what Still wrote, divided by the number of words actually spoken.
enum WordErrorRate {
    static func value(reference: String, hypothesis: String) -> Double {
        let spoken = tokens(reference)
        let written = tokens(hypothesis)
        guard !spoken.isEmpty else { return written.isEmpty ? 0 : 1 }

        return Double(editDistance(spoken, written)) / Double(spoken.count)
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func editDistance(_ first: [String], _ second: [String]) -> Int {
        var previous = Array(0...second.count)
        var current = previous

        for (i, left) in first.enumerated() {
            current[0] = i + 1
            for (j, right) in second.enumerated() {
                current[j + 1] = left == right
                    ? previous[j]
                    : min(previous[j], previous[j + 1], current[j]) + 1
            }
            swap(&previous, &current)
        }

        return previous[second.count]
    }
}

struct SpeakerSpan: Equatable, Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        max(0, end - start)
    }

    func overlap(with other: SpeakerSpan) -> TimeInterval {
        max(0, min(end, other.end) - max(start, other.start))
    }
}

/// Diarization error rate as the share of spoken time attributed to the wrong
/// group. Group names differ between runs, so reference and hypothesis labels
/// are matched by whichever pairing explains the most time.
enum DiarizationErrorRate {
    static func value(reference: [SpeakerSpan], hypothesis: [SpeakerSpan]) -> Double {
        let spoken = reference.reduce(0) { $0 + $1.duration }
        guard spoken > 0 else { return hypothesis.isEmpty ? 0 : 1 }

        var correct: TimeInterval = 0
        for mapping in pairings(reference: reference, hypothesis: hypothesis) {
            correct += agreement(reference: reference, hypothesis: hypothesis, mapping: mapping)
        }

        return max(0, (spoken - correct) / spoken)
    }

    private static func agreement(
        reference: [SpeakerSpan],
        hypothesis: [SpeakerSpan],
        mapping: [String: String]
    ) -> TimeInterval {
        var total: TimeInterval = 0
        for span in reference {
            guard let mapped = mapping[span.speaker] else { continue }
            for guess in hypothesis where guess.speaker == mapped {
                total += span.overlap(with: guess)
            }
        }
        return total
    }

    /// One pairing, the greedy best: each reference group takes the hypothesis
    /// group it shares the most time with.
    private static func pairings(reference: [SpeakerSpan], hypothesis: [SpeakerSpan]) -> [[String: String]] {
        let referenceNames = Array(Set(reference.map(\.speaker))).sorted()
        var available = Set(hypothesis.map(\.speaker))
        var mapping: [String: String] = [:]

        for name in referenceNames {
            let spans = reference.filter { $0.speaker == name }
            let best = available.max { left, right in
                shared(spans, hypothesis, left) < shared(spans, hypothesis, right)
            }
            guard let best else { break }

            mapping[name] = best
            available.remove(best)
        }

        return [mapping]
    }

    private static func shared(
        _ spans: [SpeakerSpan],
        _ hypothesis: [SpeakerSpan],
        _ candidate: String
    ) -> TimeInterval {
        var total: TimeInterval = 0
        for span in spans {
            for guess in hypothesis where guess.speaker == candidate {
                total += span.overlap(with: guess)
            }
        }
        return total
    }
}

/// The thresholds a build must clear before it can ship.
enum ReleaseGate {
    static let englishWordErrorRate = 0.12
    static let verifiedLanguageWordErrorRate = 0.18
    static let diarizationErrorRate = 0.20
    static let firstPartialSeconds: TimeInterval = 2
    static let draftLagSeconds: TimeInterval = 2
    static let hourProcessingOnIPhone13: TimeInterval = 600
    static let hourProcessingOnBaseM1: TimeInterval = 240

    static func passes(wordErrorRate: Double, language: String) -> Bool {
        wordErrorRate <= (language == "en" ? englishWordErrorRate : verifiedLanguageWordErrorRate)
    }

    static func passes(diarizationErrorRate rate: Double) -> Bool {
        rate <= diarizationErrorRate
    }
}
