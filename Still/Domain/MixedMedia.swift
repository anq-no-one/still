import Foundation

struct TimeSpan: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    var clockText: String {
        "\(start.recordingDurationText)–\(end.recordingDurationText)"
    }

    func overlaps(_ segment: TranscriptSegment) -> Bool {
        segment.start < end && segment.end > start
    }
}

struct MixedMediaLog: Sendable {
    private var openedAt: TimeInterval?
    private var finished: [TimeSpan] = []

    mutating func began(at offset: TimeInterval) {
        guard openedAt == nil else { return }
        openedAt = max(0, offset)
    }

    mutating func ended(at offset: TimeInterval) {
        guard let start = openedAt else { return }
        openedAt = nil
        finished.append(TimeSpan(start: start, end: max(start, offset)))
    }

    func spans(closingAt offset: TimeInterval) -> [TimeSpan] {
        guard let openedAt else { return finished }
        return finished + [TimeSpan(start: openedAt, end: max(openedAt, offset))]
    }
}
