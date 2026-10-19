import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class DeveloperDiagnostics {
    private(set) var channel: BuildChannel = .unknown
    @ObservationIgnored let directory: URL?
    @ObservationIgnored private let watchdog = MainThreadWatchdog()
    @ObservationIgnored private let sampler = ResourceSampler()
    @ObservationIgnored private var metrics: MetricKitCollector?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var reportedFirstFrame = false
    @ObservationIgnored private let streams: [DevLogStream]

    private static let openSessionKey = "still.developer.sessionOpen"

    init(
        directory: URL? = nil,
        key: SymmetricKey? = nil,
        defaults: UserDefaults = .standard,
        streams: (main: DevLogStream, ai: DevLogStream) = (DevLog.main, DevLog.ai)
    ) {
        self.directory = directory
        self.defaults = defaults
        self.streams = [streams.main, streams.ai]
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
        let channel = await resolve()
        self.channel = channel
        let collects = channel.collectsDeveloperDiagnostics
        for stream in streams {
            stream.setEnabled(collects)
        }
        guard collects else {
            if let metricKitDirectory { try? FileManager.default.removeItem(at: metricKitDirectory) }
            return
        }

        let previousSessionOpen = defaults.bool(forKey: Self.openSessionKey)
        defaults.set(true, forKey: Self.openSessionKey)
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
        watchdog.start()
        sampler.start()
        Interactions.observeAllInput()
        if let metricKitDirectory {
            let collector = MetricKitCollector(directory: metricKitDirectory)
            collector.start()
            metrics = collector
        }
    }

    func sceneBecame(_ phase: String) {
        watchdog.setAppActive(phase == "active")
        if phase == "background" {
            defaults.set(false, forKey: Self.openSessionKey)
        } else if phase == "active", channel.collectsDeveloperDiagnostics {
            defaults.set(true, forKey: Self.openSessionKey)
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
