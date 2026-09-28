#if os(macOS)
import CoreAudio
import Foundation

protocol AudioActivitySource: Sendable {
    func currentActivity() -> [AudioProcessActivity]
}

@MainActor
final class CallActivityWatcher: CallAppWatcher {
    static let pollInterval: Duration = .milliseconds(1_500)

    private let source: AudioActivitySource
    private let now: () -> Date
    private var detector: CallDetector
    private var loop: Task<Void, Never>?

    init(
        source: AudioActivitySource = CoreAudioActivitySource(),
        detector: CallDetector = CallDetector(),
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.detector = detector
        self.now = now
    }

    func start(
        onActivate: @escaping @MainActor (String) -> Void,
        onDeactivate: @escaping @MainActor (String) -> Void
    ) {
        stop()
        let source = source
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let activity = await Task.detached(priority: .utility) { source.currentActivity() }.value
                guard !Task.isCancelled else { return }
                self?.poll(activity, onActivate: onActivate, onDeactivate: onDeactivate)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        detector.reset()
    }

    private func poll(
        _ activity: [AudioProcessActivity],
        onActivate: @MainActor (String) -> Void,
        onDeactivate: @MainActor (String) -> Void
    ) {
        for event in detector.observe(activity, at: now()) {
            switch event {
            case .started(let bundleID): onActivate(bundleID)
            case .ended(let bundleID): onDeactivate(bundleID)
            }
        }
    }
}

struct CoreAudioActivitySource: AudioActivitySource {
    func currentActivity() -> [AudioProcessActivity] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }

        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr
        else { return [] }

        return processes.compactMap { process in
            guard let bundleID = Self.bundleID(of: process) else { return nil }
            return AudioProcessActivity(
                bundleID: bundleID,
                usesMicrophone: Self.flag(kAudioProcessPropertyIsRunningInput, of: process),
                playsAudio: Self.flag(kAudioProcessPropertyIsRunningOutput, of: process)
            )
        }
    }

    private static func flag(_ selector: AudioObjectPropertySelector, of process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let bundleID = value?.takeRetainedValue() as String?,
              !bundleID.isEmpty
        else { return nil }
        return bundleID
    }
}
#endif
