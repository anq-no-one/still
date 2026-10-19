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
        checkpoints: TranscriptionCheckpointStore,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> TranscriptionResult {
        var checkpoint = checkpoints.load()
        let totalWindows = tracks.map(windowCount).reduce(0, +)

        for captured in tracks where !captured.pcm.isEmpty {
            let speaker = checkpoint.speakers.first { $0.origin == captured.track }
                ?? Speaker.forTrack(captured.track)
            if !checkpoint.speakers.contains(where: { $0.id == speaker.id }) {
                checkpoint.speakers.append(speaker)
            }

            let bytesPerWindow = windowBytes(of: captured)
            let windows = windowCount(of: captured)

            while checkpoint.completedWindows[captured.track.rawValue, default: 0] < windows {
                try Task.checkCancellation()
                progress(Double(checkpoint.completedWindows.values.reduce(0, +)) / Double(max(1, totalWindows)))
                let index = checkpoint.completedWindows[captured.track.rawValue, default: 0]
                let start = index * bytesPerWindow
                let window = captured.pcm[start..<min(start + bytesPerWindow, captured.pcm.count)]
                let offset = captured.startOffset + TimeInterval(index) * windowSeconds

                let windowSpan = Perf.begin("transcribe.window")
                let produced = try await transcriber.segments(of: Data(window), format: captured.format)
                let audioSeconds = captured.format.duration(ofBytes: window.count)
                Perf.end(windowSpan, [
                    "recordingID": AITrace.recordingID?.uuidString ?? "-",
                    "track": captured.track.rawValue,
                    "window": String(index),
                    "audioS": String(format: "%.1f", audioSeconds),
                    "segments": String(produced.count),
                    "realtimeFactor": String(format: "%.3f", windowSpan.elapsedMS / 1000 / max(audioSeconds, 0.001)),
                ])
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
        progress(1)
        return result
    }

    private func windowBytes(of captured: CapturedTrack) -> Int {
        Int(windowSeconds * TimeInterval(captured.format.bytesPerSecond))
    }

    private func windowCount(of captured: CapturedTrack) -> Int {
        guard !captured.pcm.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(captured.pcm.count) / Double(windowBytes(of: captured)))))
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
