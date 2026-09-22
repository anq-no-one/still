import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class RecordingPlayer {
    /// Retention policies delete audio while keeping the text, so a Recording
    /// with nothing to play is an ordinary state rather than a failure.
    enum State: Equatable {
        case noAudio
        case ready
        case unreadable(String)
    }

    private var player: AVAudioPlayer?
    private var finishWatcher: PlaybackFinishWatcher?

    private(set) var state: State = .noAudio
    private(set) var isPlaying = false

    var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    var canPlay: Bool {
        state == .ready
    }

    func load(_ wav: Data) {
        guard !wav.isEmpty else {
            player = nil
            isPlaying = false
            state = .noAudio
            return
        }

        do {
            let player = try AVAudioPlayer(data: wav)
            let watcher = PlaybackFinishWatcher { [weak self] in
                self?.isPlaying = false
            }
            player.delegate = watcher
            player.prepareToPlay()

            self.player = player
            finishWatcher = watcher
            state = .ready
        } catch {
            player = nil
            finishWatcher = nil
            isPlaying = false
            state = .unreadable(error.localizedDescription)
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

/// AVAudioPlayer reports the end of playback through a delegate, which has to
/// be an NSObject, so the button does not stay offering Pause forever.
private final class PlaybackFinishWatcher: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in onFinish() }
    }
}
