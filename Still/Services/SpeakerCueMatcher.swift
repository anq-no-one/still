import Foundation

enum SpeakerCueMatcher {
    static let minimumOverlap: TimeInterval = 2
    static let minimumShare = 0.7

    static func suggest(
        _ cues: [SpeakerCue],
        for transcription: TranscriptionResult,
        ownerName: String? = nil
    ) -> TranscriptionResult {
        let heard = cues.filter { $0.duration > 0 && !VoiceProfiles.key(for: $0.name).isEmpty }
        guard !heard.isEmpty else { return transcription }

        let spans = Dictionary(grouping: heard) { VoiceProfiles.key(for: $0.name) }
        let spellings = spans.mapValues { $0[0].name }
        let overlaps = overlaps(of: transcription.segments, with: spans)
        let totalsByName = overlaps.values.reduce(into: [String: TimeInterval]()) { totals, byName in
            totals.merge(byName, uniquingKeysWith: +)
        }
        let taken = Set(
            (transcription.speakers.filter { !$0.isUnnamedGuest }.map(\.name) + [ownerName].compactMap { $0 })
                .map(VoiceProfiles.key(for:))
        )

        var result = transcription
        result.speakers = transcription.speakers.map { speaker in
            guard speaker.isUnnamedGuest,
                  let byName = overlaps[speaker.id],
                  let best = byName.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
                  best.value >= minimumOverlap,
                  best.value >= minimumShare * byName.values.reduce(0, +),
                  best.value >= minimumShare * (totalsByName[best.key] ?? 0),
                  !taken.contains(best.key),
                  let name = spellings[best.key]
            else { return speaker }
            return speaker.suggesting(name)
        }
        return result
    }

    private static func overlaps(
        of segments: [TranscriptSegment],
        with spans: [String: [SpeakerCue]]
    ) -> [UUID: [String: TimeInterval]] {
        let merged = spans.mapValues(merge)
        var overlaps: [UUID: [String: TimeInterval]] = [:]
        for segment in segments {
            guard let speakerID = segment.speakerID else { continue }
            for (key, intervals) in merged {
                let seconds = intervals.reduce(0) { total, interval in
                    total + max(0, min(interval.upperBound, segment.end) - max(interval.lowerBound, segment.start))
                }
                if seconds > 0 {
                    overlaps[speakerID, default: [:]][key, default: 0] += seconds
                }
            }
        }
        return overlaps
    }

    private static func merge(_ cues: [SpeakerCue]) -> [ClosedRange<TimeInterval>] {
        cues.sorted { $0.start < $1.start }.reduce(into: []) { merged, cue in
            if let last = merged.last, cue.start <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, cue.end)
            } else {
                merged.append(cue.start...cue.end)
            }
        }
    }
}
