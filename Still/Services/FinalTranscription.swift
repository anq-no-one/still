import Foundation

struct CapturedTrack: Equatable, Sendable {
    let track: AudioTrack
    let format: AudioFormat
    let startOffset: TimeInterval
    let pcm: Data
}

struct TranscriptionResult: Equatable, Sendable {
    var segments: [TranscriptSegment]
    var speakers: [Speaker]
}

struct FinalTranscriptionCheckpoint: Codable, Equatable, Sendable {
    var completedWindows: [String: Int]
    var segments: [TranscriptSegment]
    var speakers: [Speaker]

    static let empty = FinalTranscriptionCheckpoint(completedWindows: [:], segments: [], speakers: [])
}

protocol TranscriptionCheckpointStore: Sendable {
    func load() -> FinalTranscriptionCheckpoint
    func save(_ checkpoint: FinalTranscriptionCheckpoint)
    func clear()
}

/// Reads the journaled audio without touching it and transcribes each track on
/// its own, one window at a time behind a checkpoint. Keeping the tracks apart
/// is what lets Still say which words came from the microphone.
struct FinalTranscription: Sendable {
    let transcriber: OfflineTranscriber
    let windowSeconds: TimeInterval

    init(transcriber: OfflineTranscriber, windowSeconds: TimeInterval = 60) {
        self.transcriber = transcriber
        self.windowSeconds = windowSeconds
    }

    func run(
        tracks: [CapturedTrack],
        checkpoints: TranscriptionCheckpointStore
    ) async throws -> TranscriptionResult {
        var checkpoint = checkpoints.load()

        for captured in tracks where !captured.pcm.isEmpty {
            let speaker = checkpoint.speakers.first { $0.origin == captured.track }
                ?? Speaker.forTrack(captured.track)
            if !checkpoint.speakers.contains(where: { $0.id == speaker.id }) {
                checkpoint.speakers.append(speaker)
            }

            let windowBytes = Int(windowSeconds * TimeInterval(captured.format.bytesPerSecond))
            let windowCount = max(1, Int(ceil(Double(captured.pcm.count) / Double(windowBytes))))

            while checkpoint.completedWindows[captured.track.rawValue, default: 0] < windowCount {
                let index = checkpoint.completedWindows[captured.track.rawValue, default: 0]
                let start = index * windowBytes
                let window = captured.pcm[start..<min(start + windowBytes, captured.pcm.count)]
                let offset = captured.startOffset + TimeInterval(index) * windowSeconds

                let produced = try await transcriber.segments(of: Data(window), format: captured.format)
                checkpoint.segments += produced.map { $0.offset(by: offset).attributed(to: speaker) }
                checkpoint.completedWindows[captured.track.rawValue] = index + 1
                checkpoints.save(checkpoint)
            }
        }

        let result = TranscriptionResult(
            segments: EchoFilter.removingEcho(from: checkpoint.segments, speakers: checkpoint.speakers)
                .sorted { $0.start < $1.start },
            speakers: checkpoint.speakers
        )
        checkpoints.clear()
        return result
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
