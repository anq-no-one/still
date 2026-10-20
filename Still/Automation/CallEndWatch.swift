import Foundation

/// A recording that overlapped a call ends with the call, whatever started it:
/// the Record button, a shortcut, or a browser meeting whose end signal never
/// arrived. Call apps keep the microphone open while muted, so a call is over
/// only once none of them has held it for the quiet period. A recording that
/// never overlapped a call, such as an in-person meeting, is left alone.
struct CallEndDetector {
    static let defaultQuietPeriod: TimeInterval = 30

    private let quietPeriod: TimeInterval
    private var lastCallHeard: Date?

    init(quietPeriod: TimeInterval = Self.defaultQuietPeriod) {
        self.quietPeriod = quietPeriod
    }

    mutating func observe(_ activity: [AudioProcessActivity], isRecording: Bool, at now: Date) -> Bool {
        guard isRecording else {
            lastCallHeard = nil
            return false
        }
        if activity.contains(where: { $0.usesMicrophone && Self.holdsCalls($0.bundleID) }) {
            lastCallHeard = now
            return false
        }
        guard let lastCallHeard, now.timeIntervalSince(lastCallHeard) >= quietPeriod else { return false }
        self.lastCallHeard = nil
        return true
    }

    static func holdsCalls(_ processBundleID: String) -> Bool {
        CallApp.owner(of: processBundleID) != nil
            || WebBrowser.all.contains { processBundleID == $0.bundleID || processBundleID.hasPrefix($0.bundleID + ".") }
            || processBundleID.hasPrefix("com.apple.WebKit.")
    }
}

#if os(macOS)
@MainActor
final class CallEndWatch {
    static let pollInterval: Duration = .seconds(3)

    private let coordinator: RecordingCoordinator
    private let source: AudioActivitySource
    private let now: () -> Date
    private var detector = CallEndDetector()
    private var loop: Task<Void, Never>?

    init(
        coordinator: RecordingCoordinator,
        source: AudioActivitySource = CoreAudioActivitySource(),
        now: @escaping () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.source = source
        self.now = now
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func check() async {
        let isRecording = coordinator.isRecording
        var activity: [AudioProcessActivity] = []
        if isRecording {
            let source = source
            activity = await Task.detached(priority: .utility) { source.currentActivity() }.value
        }
        guard detector.observe(activity, isRecording: isRecording && coordinator.isRecording, at: now()) else { return }
        DevLog.event("record.callEnded", ["quietS": String(format: "%.0f", CallEndDetector.defaultQuietPeriod)])
        await coordinator.stopAndSave()
    }
}
#endif
