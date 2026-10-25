import CryptoKit
import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
final class DeveloperDiagnostics {
    private(set) var channel: BuildChannel = .unknown
    @ObservationIgnored let directory: URL?
    @ObservationIgnored private let watchdog: MainThreadWatchdog
    @ObservationIgnored private let sampler = ResourceSampler()
    @ObservationIgnored private let memoryPressure = MemoryPressureMonitor()
    @ObservationIgnored private var metrics: MetricKitCollector?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var reportedFirstFrame = false
    @ObservationIgnored private let streams: [DevLogStream]
    @ObservationIgnored private var resolver: () async -> BuildChannel = { await BuildChannelResolver.resolve() }
    @ObservationIgnored private var startsMonitors = true
    @ObservationIgnored private var collectingHooks: [@MainActor () -> Void] = []
    @ObservationIgnored private var isCollecting = false
    @ObservationIgnored let savedBundles: DebugBundleStore?

    private static let openSessionKey = "still.developer.sessionOpen"
    #if os(macOS)
    private static let willTerminate = NSApplication.willTerminateNotification
    #else
    private static let willTerminate = UIApplication.willTerminateNotification
    #endif

    init(
        directory: URL? = nil,
        key: SymmetricKey? = nil,
        defaults: UserDefaults = .standard,
        streams: (main: DevLogStream, ai: DevLogStream) = (DevLog.main, DevLog.ai),
        savedBundles: DebugBundleStore? = nil
    ) {
        self.savedBundles = savedBundles
        self.directory = directory
        self.defaults = defaults
        self.streams = [streams.main, streams.ai]
        let markers = directory.map { ProblemMarkers(directory: $0.appending(path: "Markers", directoryHint: .isDirectory)) }
        watchdog = MainThreadWatchdog(stream: streams.main) {
            markers?.capture(ProblemMarker(reason: .longHang, note: "main thread blocked for 2 s", screen: "-"))
        }
        ProcessProbe.registerMainThread()
        if let directory, let key {
            streams.main.configure(directory: directory, name: "devlog", key: key)
            streams.ai.configure(directory: directory, name: "ai-trace", key: key)
        }
    }

    var allowsDebugBundle: Bool {
        channel.collectsDeveloperDiagnostics
    }

    var metricKitDirectory: URL? {
        directory?.appending(path: "MetricKit", directoryHint: .isDirectory)
    }

    func start(
        startsMonitors: Bool = true,
        resolve: @escaping () async -> BuildChannel = { await BuildChannelResolver.resolve() }
    ) async {
        resolver = resolve
        self.startsMonitors = startsMonitors
        apply(await resolve())
    }

    /// StoreKit sometimes cannot answer at launch. An unknown channel keeps
    /// holding records in memory, neither writing nor deleting them, until a
    /// later attempt names the channel.
    func resolveAgainIfUnknown() async {
        guard channel == .unknown else { return }
        apply(await resolver())
    }

    private func apply(_ channel: BuildChannel) {
        guard self.channel == .unknown else { return }
        self.channel = channel
        guard channel != .unknown else { return }
        let collects = channel.collectsDeveloperDiagnostics
        for stream in streams {
            stream.setEnabled(collects)
        }
        guard collects else {
            if let metricKitDirectory { try? FileManager.default.removeItem(at: metricKitDirectory) }
            if let directory { Self.removeCrashFiles(in: directory) }
            if let markersDirectory { try? FileManager.default.removeItem(at: markersDirectory) }
            savedBundles?.removeAll()
            return
        }

        let previousSessionOpen = defaults.bool(forKey: Self.openSessionKey)
        defaults.set(true, forKey: Self.openSessionKey)
        let defaults = defaults
        NotificationCenter.default.addObserver(forName: Self.willTerminate, object: nil, queue: nil) { _ in
            defaults.set(false, forKey: Self.openSessionKey)
        }
        let environment = Diagnostics.systemEnvironment()
        var fields = [
            "channel": channel.rawValue,
            "version": environment.appVersion,
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            "os": environment.systemVersion,
            "previousSessionEndedAbruptly": String(previousSessionOpen),
        ]
        if let started = DevLogClock.processStartedAt {
            fields["processStartToResolveMS"] = String(format: "%.0f", Date.now.timeIntervalSince(started) * 1000)
        }
        DevLog.event("session.start", fields)

        guard startsMonitors else { return }
        if let directory {
            let crashes = CrashMarker.collectPrevious(in: directory)
            for report in crashes {
                DevLog.event("crash.previous", report.fields)
            }
            if let crash = crashes.first {
                previousLaunchProblem = "Still crashed last time (\(crash.title))."
            } else if previousSessionOpen {
                previousLaunchProblem = "Still quit unexpectedly last time."
            }
            CrashMarker.install(in: directory)
        }
        watchdog.start()
        sampler.start()
        memoryPressure.start()
        isCollecting = true
        collectingHooks.forEach { $0() }
        collectingHooks.removeAll()
        Interactions.observeAllInput()
        if let metricKitDirectory {
            let collector = MetricKitCollector(directory: metricKitDirectory)
            collector.start()
            metrics = collector
        }
    }

    /// Runs `body` once developer diagnostics are on, for monitors that live
    /// outside this module, such as audio route logging.
    func whenCollecting(_ body: @escaping @MainActor () -> Void) {
        if isCollecting {
            body()
        } else {
            collectingHooks.append(body)
        }
    }

    var markersDirectory: URL? {
        directory?.appending(path: "Markers", directoryHint: .isDirectory)
    }

    var markers: ProblemMarkers? {
        markersDirectory.map { ProblemMarkers(directory: $0) }
    }

    /// Set when the last launch crashed or ended without going to the
    /// background first, so the app can offer to report it.
    private(set) var previousLaunchProblem: String?

    func dismissPreviousLaunchProblem() {
        previousLaunchProblem = nil
    }

    var crashesDirectory: URL? {
        directory.map(CrashMarker.crashesDirectory(in:))
    }

    private static func removeCrashFiles(in directory: URL) {
        for url in [CrashMarker.markerURL(in: directory), CrashMarker.imagesURL(in: directory), CrashMarker.crashesDirectory(in: directory)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func sceneBecame(_ phase: String) {
        watchdog.setAppActive(phase == "active")
        if phase == "background" {
            defaults.set(false, forKey: Self.openSessionKey)
        } else if phase == "active", channel.collectsDeveloperDiagnostics {
            defaults.set(true, forKey: Self.openSessionKey)
        } else if phase == "active", channel == .unknown {
            Task { await resolveAgainIfUnknown() }
        }
        DevLog.event("scene.\(phase)")
    }

    func firstFrame() {
        guard !reportedFirstFrame else { return }
        reportedFirstFrame = true
        var fields: [String: String] = [:]
        if let started = DevLogClock.processStartedAt {
            fields["sinceProcessStartMS"] = String(format: "%.0f", Date.now.timeIntervalSince(started) * 1000)
        }
        DevLog.main.append(DevLog.record(.span, "launch.firstFrame", ms: DevLogClock.sinceLaunch * 1000, fields: fields))
    }
}
