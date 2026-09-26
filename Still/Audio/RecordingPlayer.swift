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

    private var box = PlayerBox()
    private var loadGeneration = 0

    private(set) var state: State = .noAudio
    private(set) var isPlaying = false

    var currentTime: TimeInterval {
        box.player?.currentTime ?? 0
    }

    var canPlay: Bool {
        state == .ready
    }

    /// Decoding into buffers happens on the playback thread, so opening a
    /// long recording never stalls the interface. The state flips when the
    /// buffers are ready; a newer load discards an older one still in flight.
    func load(_ wav: Data) async {
        loadGeneration += 1
        let generation = loadGeneration
        retireBox()
        guard !wav.isEmpty else {
            isPlaying = false
            state = .noAudio
            return
        }

        let watcher = PlaybackFinishWatcher { [weak self] in self?.isPlaying = false }
        let box = box
        let prepared = await AudioPlaybackThread.shared.run { () -> Result<Void, Error> in
            do {
                let player = try AVAudioPlayer(data: wav)
                player.delegate = watcher
                player.prepareToPlay()
                box.player = player
                box.watcher = watcher
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        guard generation == loadGeneration else { return }
        switch prepared {
        case .success:
            state = .ready
        case .failure(let error):
            retireBox()
            isPlaying = false
            state = .unreadable(error.localizedDescription)
        }
    }

    /// Session activation on the first play can block, so it runs on the
    /// playback thread. The finishing flag still arrives through the delegate,
    /// which only fires on a thread with a running loop.
    func play(from time: TimeInterval) {
        guard state == .ready else { return }
        let box = box
        Task { @MainActor [weak self] in
            let started = await AudioPlaybackThread.shared.run {
                box.player?.currentTime = min(max(0, time), box.player?.duration ?? time)
                return box.player?.play() ?? false
            }
            self?.isPlaying = started
        }
    }

    func pause() {
        isPlaying = false
        let box = box
        AudioPlaybackThread.shared.perform { box.player?.pause() }
    }

    private func retireBox() {
        let old = box
        box = PlayerBox()
        AudioPlaybackThread.shared.perform { old.player?.stop() }
    }
}

/// The player and its delegate outlive any single call, but every touch
/// happens on the playback thread, so sharing the box is safe.
private final class PlayerBox: @unchecked Sendable {
    var player: AVAudioPlayer?
    var watcher: PlaybackFinishWatcher?
}

/// AVAudioPlayer reports the end of playback through a delegate, which has to
/// be an NSObject, so the button does not stay offering Pause forever.
private final class PlaybackFinishWatcher: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @Sendable @MainActor () -> Void

    init(onFinish: @escaping @Sendable @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish()
    }

    private func finish() {
        let onFinish = onFinish
        Task { @MainActor in onFinish() }
    }
}
