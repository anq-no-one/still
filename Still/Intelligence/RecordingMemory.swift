import CryptoKit
import Foundation

struct ExtractionRun: Codable, Equatable, Sendable {
    let fingerprint: String
    let startedAt: Date
    let totalChunks: Int
    var completedChunks = 0
    var withheldCount = 0

    var isComplete: Bool {
        completedChunks >= totalChunks
    }

    func isSameRun(as other: ExtractionRun?) -> Bool {
        other.map { $0.fingerprint == fingerprint && $0.startedAt == startedAt } ?? false
    }

    static func fingerprint(of segments: [TranscriptSegment]) -> String {
        let key = segments.map { "\($0.id.uuidString):\($0.displayText)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct RecordingMemory: Codable, Equatable, Sendable {
    private(set) var items: [MemoryItem] = []
    private(set) var run: ExtractionRun?

    init(items: [MemoryItem] = [], run: ExtractionRun? = nil) {
        self.items = Self.ordered(items)
        self.run = run
    }

    func items(of kind: MemoryKind) -> [MemoryItem] {
        items.filter { $0.kind == kind }
    }

    func item(withID id: String) -> MemoryItem? {
        items.first { $0.id == id }
    }

    var acceptedTasks: [MemoryItem] {
        items.filter { $0.status == .accepted }
    }

    func beginning(_ run: ExtractionRun) -> RecordingMemory {
        RecordingMemory(items: items.filter(\.isUserTouched), run: run)
    }

    func absorbing(_ extracted: [MemoryItem], withheld: Int, completedChunks: Int) -> RecordingMemory {
        let known = Set(items.map(\.id))
        var seen = Set<String>()
        let fresh = extracted.filter { !known.contains($0.id) && seen.insert($0.id).inserted }
        var progress = run
        progress?.completedChunks = max(run?.completedChunks ?? 0, completedChunks)
        progress?.withheldCount += withheld
        return RecordingMemory(items: items + fresh, run: progress)
    }

    func updating(_ id: String, _ change: (MemoryItem) -> MemoryItem) -> RecordingMemory {
        RecordingMemory(items: items.map { $0.id == id ? change($0) : $0 }, run: run)
    }

    static func merge(_ first: RecordingMemory?, _ second: RecordingMemory?) -> RecordingMemory? {
        guard let first else { return second }
        guard let second else { return first }

        let (newer, older) = isNewer(first.run, than: second.run) ? (first, second) : (second, first)
        let sameRun = newer.run.map { $0.isSameRun(as: older.run) } ?? (older.run == nil)

        var merged = newer.items
        var positions = Dictionary(merged.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in older.items {
            if let position = positions[item.id] {
                merged[position] = MemoryItem.merge(merged[position], item)
            } else if sameRun || item.isUserTouched {
                positions[item.id] = merged.count
                merged.append(item)
            }
        }

        return RecordingMemory(items: merged, run: newer.run)
    }

    private static func isNewer(_ first: ExtractionRun?, than second: ExtractionRun?) -> Bool {
        guard let first else { return second == nil }
        guard let second else { return true }

        if first.startedAt != second.startedAt { return first.startedAt > second.startedAt }
        if first.fingerprint != second.fingerprint { return first.fingerprint > second.fingerprint }
        if first.completedChunks != second.completedChunks { return first.completedChunks > second.completedChunks }
        return first.withheldCount >= second.withheldCount
    }

    private static func ordered(_ items: [MemoryItem]) -> [MemoryItem] {
        items.sorted { ($0.sourceStart, $0.kind.rawValue, $0.id) < ($1.sourceStart, $1.kind.rawValue, $1.id) }
    }
}

extension Recording {
    var isReadyForExtraction: Bool {
        isProjectConfirmed && !isDeleted && !segments.isEmpty
    }

    var needsExtraction: Bool {
        isReadyForExtraction && memory?.run?.isComplete != true
    }

    func keepingMemory(of other: Recording) -> Recording {
        var result = self
        result.memory = RecordingMemory.merge(memory, other.memory)
        return result
    }
}

struct SourcedItem: Identifiable, Equatable, Sendable {
    let item: MemoryItem
    let recordingID: UUID
    let recordingTitle: String
    let recordingDate: Date

    init(_ item: MemoryItem, in recording: Recording) {
        self.item = item
        recordingID = recording.id
        recordingTitle = recording.title
        recordingDate = recording.createdAt
    }

    var id: String {
        "\(recordingID.uuidString)-\(item.id)"
    }

    var time: TimeInterval {
        item.sourceStart
    }

    static func acceptedTasks(in recordings: [Recording], project projectID: UUID) -> [SourcedItem] {
        recordings
            .filter { $0.projectID == projectID && $0.isProjectConfirmed && !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
            .flatMap { recording in
                (recording.memory?.acceptedTasks ?? []).map { SourcedItem($0, in: recording) }
            }
    }
}
