import Foundation

struct FinalTranscriptionCheckpoint: Codable, Equatable, Sendable {
    var completedWindows: Int
    var segments: [TranscriptSegment]

    static let empty = FinalTranscriptionCheckpoint(completedWindows: 0, segments: [])
}

protocol TranscriptionCheckpointStore: Sendable {
    func load() -> FinalTranscriptionCheckpoint
    func save(_ checkpoint: FinalTranscriptionCheckpoint)
    func clear()
}

/// Reads the journaled audio without touching it and transcribes it one window
/// at a time, saving a checkpoint after each window so an interrupted pass
/// resumes instead of starting over.
struct FinalTranscription: Sendable {
    let transcriber: OfflineTranscriber
    let windowSeconds: TimeInterval

    init(transcriber: OfflineTranscriber, windowSeconds: TimeInterval = 60) {
        self.transcriber = transcriber
        self.windowSeconds = windowSeconds
    }

    func run(
        pcm: Data,
        format: AudioFormat,
        checkpoints: TranscriptionCheckpointStore
    ) async throws -> [TranscriptSegment] {
        let windowBytes = Int(windowSeconds * TimeInterval(format.bytesPerSecond))
        let windowCount = max(1, Int(ceil(Double(pcm.count) / Double(windowBytes))))
        var checkpoint = checkpoints.load()

        while checkpoint.completedWindows < windowCount {
            let index = checkpoint.completedWindows
            let start = index * windowBytes
            let window = pcm[start..<min(start + windowBytes, pcm.count)]

            let produced = try await transcriber.segments(of: Data(window), format: format)
            checkpoint.segments += produced.map { $0.offset(by: TimeInterval(index) * windowSeconds) }
            checkpoint.completedWindows = index + 1
            checkpoints.save(checkpoint)
        }

        let segments = checkpoint.segments
        checkpoints.clear()
        return segments
    }
}

struct SealedCheckpointStore: TranscriptionCheckpointStore, @unchecked Sendable {
    let url: URL
    let cipher: LibraryCipher

    func load() -> FinalTranscriptionCheckpoint {
        guard let sealed = try? Data(contentsOf: url),
              let data = try? cipher.open(sealed),
              let checkpoint = try? JSONDecoder().decode(FinalTranscriptionCheckpoint.self, from: data)
        else { return .empty }

        return checkpoint
    }

    func save(_ checkpoint: FinalTranscriptionCheckpoint) {
        guard let data = try? JSONEncoder().encode(checkpoint),
              let sealed = try? cipher.seal(data)
        else { return }

        try? sealed.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
