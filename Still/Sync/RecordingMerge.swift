import Foundation

/// Merges two versions of one Recording. Generated content follows the newer
/// write, because a later pass supersedes an earlier one. Text a person typed
/// is never dropped: when two devices disagree, both readings survive, joined
/// in a fixed order so every device reaches the same result.
enum RecordingMerge {
    static let separator = " / "

    static func merge(_ local: Recording, _ remote: Recording) -> Recording {
        guard local.id == remote.id else { return local }

        let newer = local.updatedAt >= remote.updatedAt ? local : remote
        let older = local.updatedAt >= remote.updatedAt ? remote : local

        var merged = newer
        merged.title = union(local.title, remote.title)
        merged.segments = mergeSegments(newer.segments, older.segments)
        merged.note = mergeNote(newer.note, older.note)
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        return merged
    }

    private static func mergeSegments(
        _ newer: [TranscriptSegment],
        _ older: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        let olderByID = Dictionary(older.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return newer.map { segment in
            guard let other = olderByID[segment.id] else { return segment }

            var merged = segment
            merged.correction = unionOptional(segment.correction, other.correction)
            return merged
        }
    }

    private static func mergeNote(_ newer: Note?, _ older: Note?) -> Note? {
        guard let newer else { return older }
        guard let older else { return newer }

        var merged = newer
        merged.userText = union(newer.userText, older.userText)
        merged.actions = mergeItems(newer.actions, older.actions)
        merged.decisions = mergeItems(newer.decisions, older.decisions)
        merged.summary = mergeItems(newer.summary, older.summary)
        return merged
    }

    /// An item a person added on one device is not generated output, so a
    /// regenerated note from the other device must not erase it.
    private static func mergeItems(_ newer: [NoteItem], _ older: [NoteItem]) -> [NoteItem] {
        let known = Set(newer.map(\.id))
        return newer + older.filter { $0.isUserAuthored && !known.contains($0.id) }
    }

    private static func unionOptional(_ first: String?, _ second: String?) -> String? {
        switch (first, second) {
        case (nil, nil): nil
        case (let value?, nil): value
        case (nil, let value?): value
        case (let first?, let second?): union(first, second)
        }
    }

    private static func union(_ first: String, _ second: String) -> String {
        guard first != second else { return first }
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }

        return [first, second].sorted().joined(separator: separator)
    }
}
