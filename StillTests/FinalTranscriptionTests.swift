import Foundation
import Testing
@testable import Still

struct FinalTranscriptionTests {
    private let format = AudioFormat(sampleRate: 1_000, channels: 1, bitsPerSample: 16)

    @Test
    func timesSegmentsAgainstTheWholeRecording() async throws {
        let transcriber = WindowTranscriber()
        let checkpoints = MemoryCheckpointStore()
        let final = FinalTranscription(transcriber: transcriber, windowSeconds: 10)

        let result = try await final.run(tracks: [track(.microphone, seconds: 25)], checkpoints: checkpoints)

        #expect(result.segments.map(\.start) == [0, 10, 20])
        #expect(result.segments.map(\.text) == ["window 0", "window 1", "window 2"])
        #expect(result.segments.plainText == "window 0 window 1 window 2")
    }

    @Test
    func attributesEachTrackToItsOwnSpeakerOnOneTimeline() async throws {
        let transcriber = WindowTranscriber()
        let final = FinalTranscription(transcriber: transcriber, windowSeconds: 10)

        let result = try await final.run(
            tracks: [
                track(.microphone, seconds: 10),
                track(.system, seconds: 10, startOffset: 5),
            ],
            checkpoints: MemoryCheckpointStore()
        )

        #expect(result.speakers.count == 2)
        let you = try #require(result.speakers.first { $0.isYou })
        #expect(you.origin == .microphone)
        #expect(result.segments.map(\.start) == [0, 5])
        #expect(result.segments[0].speakerID == you.id)
        #expect(result.segments[1].speakerID != you.id)
    }

    @Test
    func aSingleTrackStaysOneGenericGroup() async throws {
        let result = try await FinalTranscription(transcriber: WindowTranscriber(), windowSeconds: 10)
            .run(tracks: [track(.microphone, seconds: 10)], checkpoints: MemoryCheckpointStore())

        #expect(result.speakers.map(\.name) == [Speaker.forTrack(.microphone).name])
    }

    @Test
    func resumesFromTheLastCompletedWindow() async throws {
        let transcriber = WindowTranscriber()
        transcriber.failsAtCall = 3
        let checkpoints = MemoryCheckpointStore()
        let final = FinalTranscription(transcriber: transcriber, windowSeconds: 10)
        let pcm = track(.microphone, seconds: 35)

        await #expect(throws: WindowTranscriber.Interrupted.self) {
            try await final.run(tracks: [pcm], checkpoints: checkpoints)
        }
        #expect(checkpoints.stored?.completedWindows[AudioTrack.microphone.rawValue] == 2)

        transcriber.failsAtCall = nil
        let result = try await final.run(tracks: [pcm], checkpoints: checkpoints)

        #expect(result.segments.count == 4)
        #expect(transcriber.transcribedWindows == 5)
        #expect(checkpoints.stored == nil)
    }

    @Test
    func keepsSourceAudioUntouched() async throws {
        let captured = track(.microphone, seconds: 12)

        _ = try await FinalTranscription(transcriber: WindowTranscriber(), windowSeconds: 10)
            .run(tracks: [captured], checkpoints: MemoryCheckpointStore())

        #expect(captured.pcm == audio(seconds: 12))
    }

    @Test
    func marksUnsureWordsInsteadOfInventingThem() {
        let unsure = TranscriptSegment(start: 0, end: 1, text: "maybe", language: "en", confidence: 0.1)
        let missing = TranscriptSegment(start: 1, end: 2, text: "unknown", language: "en", confidence: nil)
        let sure = TranscriptSegment(start: 2, end: 3, text: "clear", language: "en", confidence: 0.9)

        #expect(unsure.isUncertain)
        #expect(missing.isUncertain)
        #expect(!sure.isUncertain)
    }

    @Test
    func keepsSegmentIdentityAndRevisionAcrossOffsets() {
        let segment = TranscriptSegment(start: 1, end: 2, text: "text", language: "en", confidence: 0.8)

        let moved = segment.offset(by: 30)

        #expect(moved.id == segment.id)
        #expect(moved.revision == segment.revision)
        #expect(moved.start == 31)
        #expect(moved.end == 32)
    }

    private func track(_ track: AudioTrack, seconds: Int, startOffset: TimeInterval = 0) -> CapturedTrack {
        CapturedTrack(track: track, format: format, startOffset: startOffset, pcm: audio(seconds: seconds))
    }

    private func audio(seconds: Int) -> Data {
        Data(repeating: 9, count: seconds * format.bytesPerSecond)
    }
}

final class WindowTranscriber: OfflineTranscriber, @unchecked Sendable {
    struct Interrupted: Error {}

    var failsAtCall: Int?
    private(set) var transcribedWindows = 0
    private var index = 0

    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment] {
        transcribedWindows += 1
        if let failsAtCall, transcribedWindows == failsAtCall { throw Interrupted() }

        defer { index += 1 }
        return [
            TranscriptSegment(start: 0, end: 5, text: "window \(index)", language: "en", confidence: 0.9)
        ]
    }
}

final class MemoryCheckpointStore: TranscriptionCheckpointStore, @unchecked Sendable {
    private(set) var stored: FinalTranscriptionCheckpoint?

    func load() -> FinalTranscriptionCheckpoint { stored ?? .empty }
    func save(_ checkpoint: FinalTranscriptionCheckpoint) { stored = checkpoint }
    func clear() { stored = nil }
}
