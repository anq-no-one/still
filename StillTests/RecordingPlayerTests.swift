import Foundation
import Testing
@testable import Still

@MainActor
struct RecordingPlayerTests {
    @Test
    func aRecordingWhoseAudioWasDeletedIsNotAnError() {
        let player = RecordingPlayer()

        player.load(Data())

        #expect(player.state == .noAudio)
        #expect(!player.canPlay)
        #expect(!player.isPlaying)
    }

    @Test
    func damagedAudioReadsAsUnreadableRatherThanMissing() {
        let player = RecordingPlayer()

        player.load(Data(repeating: 0xAB, count: 512))

        #expect(player.canPlay == false)
        if case .unreadable = player.state {
            #expect(Bool(true))
        } else {
            Issue.record("damaged audio should be unreadable, got \(player.state)")
        }
    }

    @Test
    func realAudioLoadsAndIsPlayable() {
        let format = AudioFormat(sampleRate: 8_000, channels: 1, bitsPerSample: 16)
        let silence = Data(count: format.bytesPerSecond)
        let player = RecordingPlayer()

        player.load(WAVFile.data(pcm: silence, format: format))

        #expect(player.state == .ready)
        #expect(player.canPlay)
        #expect(!player.isPlaying)
    }

    @Test
    func playingThenPausingLeavesNothingRunning() {
        let format = AudioFormat(sampleRate: 8_000, channels: 1, bitsPerSample: 16)
        let player = RecordingPlayer()
        player.load(WAVFile.data(pcm: Data(count: format.bytesPerSecond * 2), format: format))

        player.play(from: 0)

        #expect(player.isPlaying)

        player.pause()

        #expect(!player.isPlaying)
    }
}
