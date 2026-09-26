import Foundation

/// One thread with its own run loop for blocking audio calls.
///
/// AVAudioPlayer decodes buffers in `prepareToPlay` and can activate the
/// audio session in `play`, either of which stalls the main thread. Both
/// calls also have to happen on a thread that pumps a run loop, otherwise
/// the player's delegate never reports the end of playback. A detached task
/// has no run loop, so playback owns this thread instead.
/// Set once during init and never reassigned; `perform` is thread-safe.
final class AudioPlaybackThread: @unchecked Sendable {
    static let shared = AudioPlaybackThread()

    private let thread: Thread

    private init() {
        let thread = Thread {
            Thread.current.name = "com.andrii.still.playback"
            Thread.current.qualityOfService = .userInitiated
            RunLoop.current.add(NSMachPort(), forMode: .default)
            RunLoop.current.run()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        self.thread = thread
    }

    func perform(_ work: @escaping @Sendable () -> Void) {
        WorkItem(work).perform(
            #selector(WorkItem.run),
            on: thread,
            with: nil,
            waitUntilDone: false,
            modes: [RunLoop.Mode.default.rawValue]
        )
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            perform { continuation.resume(returning: work()) }
        }
    }
}

private final class WorkItem: NSObject {
    private let work: @Sendable () -> Void

    init(_ work: @escaping @Sendable () -> Void) {
        self.work = work
    }

    @objc func run() {
        work()
    }
}
