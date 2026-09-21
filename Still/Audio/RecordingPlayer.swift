import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class RecordingPlayer {
    private var player: AVAudioPlayer?

    private(set) var isPlaying = false
    private(set) var loadFailure: String?

    var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    func load(_ wav: Data) {
        do {
            let player = try AVAudioPlayer(data: wav)
            player.prepareToPlay()
            self.player = player
            loadFailure = nil
        } catch {
            player = nil
            loadFailure = error.localizedDescription
        }
    }

    func play(from time: TimeInterval) {
        guard let player else { return }

        player.currentTime = min(max(0, time), player.duration)
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }
}
