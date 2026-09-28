import Foundation
import Observation

struct CallApp: Identifiable, Equatable, Sendable {
    var id: String { bundleID }

    let bundleID: String
    let name: String
    var isAllowed: Bool

    static let known: [CallApp] = [
        CallApp(bundleID: "us.zoom.xos", name: "Zoom", isAllowed: false),
        CallApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", isAllowed: false),
        CallApp(bundleID: "Cisco-Systems.Spark", name: "Webex", isAllowed: false),
        CallApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex Meetings", isAllowed: false),
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isAllowed: false),
        CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime", isAllowed: false),
        CallApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram", isAllowed: false),
        CallApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", isAllowed: false),
        CallApp(bundleID: "com.hnc.Discord", name: "Discord", isAllowed: false),
    ]

    private static let audioProcesses: [String: [String]] = [
        "com.apple.FaceTime": ["com.apple.avconferenced"],
    ]

    static func owner(of processBundleID: String) -> CallApp? {
        known.first { $0.owns(processBundleID) }
    }

    var processBundleIDs: [String] {
        [bundleID] + (Self.audioProcesses[bundleID] ?? [])
    }

    func owns(_ processBundleID: String) -> Bool {
        processBundleIDs.contains { processBundleID == $0 || processBundleID.hasPrefix($0 + ".") }
    }
}

protocol CallAppAllowList: Sendable {
    var watches: Bool { get }
    func apps() -> [CallApp]
    func setAllowed(_ allowed: Bool, forBundleID bundleID: String)
    func setWatching(_ watching: Bool)
}

@MainActor
protocol CallAppWatcher: AnyObject {
    func start(onActivate: @escaping @MainActor (String) -> Void, onDeactivate: @escaping @MainActor (String) -> Void)
    func stop()
}

@MainActor
@Observable
final class AutomaticRecording {
    static let meetingLength: TimeInterval = 45

    private let coordinator: RecordingCoordinator
    private let watcher: CallAppWatcher
    private let allowList: CallAppAllowList
    private let meetingEvidence: @MainActor (Date) async -> Bool
    private let now: () -> Date

    private(set) var isWatching = false
    private(set) var triggeredBy: String?
    private(set) var startedAt: Date?
    private(set) var isKept = false
    private(set) var discardedCheck: String?
    private(set) var apps: [CallApp]

    init(
        coordinator: RecordingCoordinator,
        watcher: CallAppWatcher,
        allowList: CallAppAllowList,
        meetingEvidence: @escaping @MainActor (Date) async -> Bool = { _ in false },
        now: @escaping () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.watcher = watcher
        self.allowList = allowList
        self.meetingEvidence = meetingEvidence
        self.now = now
        apps = allowList.apps()
        if allowList.watches {
            startWatching()
        }
    }

    func startWatching() {
        guard !isWatching else { return }

        watcher.start(
            onActivate: { [weak self] bundleID in
                Task { await self?.appBecameActive(bundleID) }
            },
            onDeactivate: { [weak self] bundleID in
                Task { await self?.appWentAway(bundleID) }
            }
        )
        isWatching = true
        allowList.setWatching(true)
    }

    func stopWatching() {
        watcher.stop()
        isWatching = false
        allowList.setWatching(false)
    }

    func reload() {
        apps = allowList.apps()
        if allowList.watches, !isWatching {
            startWatching()
        } else if !allowList.watches, isWatching {
            stopWatching()
        }
    }

    func setAllowed(_ allowed: Bool, for app: CallApp) {
        allowList.setAllowed(allowed, forBundleID: app.bundleID)
        apps = allowList.apps()

        if !allowed, triggeredBy == app.bundleID {
            triggeredBy = nil
        }
    }

    var triggeringApp: CallApp? {
        triggeredBy.flatMap { id in apps.first { $0.bundleID == id } }
    }

    func keep() {
        guard triggeredBy != nil else { return }
        isKept = true
    }

    func discardAutomaticRecording() async {
        await coordinator.cancel()
        finish()
    }

    private func appBecameActive(_ processBundleID: String) async {
        guard isWatching,
              triggeredBy == nil,
              !coordinator.isRecording,
              let owner = CallApp.owner(of: processBundleID),
              let app = apps.first(where: { $0.isAllowed && $0.bundleID == owner.bundleID })
        else { return }

        triggeredBy = app.bundleID
        startedAt = now()
        isKept = false
        discardedCheck = nil
        await coordinator.start(capturing: .app(app))
    }

    private func appWentAway(_ processBundleID: String) async {
        guard let triggeredBy, CallApp.owner(of: processBundleID)?.bundleID == triggeredBy else { return }

        let app = triggeringApp
        let wasMeeting = await isMeeting()
        finish()
        guard coordinator.isCapturing else { return }

        if wasMeeting {
            await coordinator.stopAndSave()
        } else {
            await coordinator.cancel()
            discardedCheck = app?.name
        }
    }

    private func isMeeting() async -> Bool {
        guard let startedAt else { return false }
        if isKept || now().timeIntervalSince(startedAt) >= Self.meetingLength {
            return true
        }
        return await meetingEvidence(startedAt)
    }

    private func finish() {
        triggeredBy = nil
        startedAt = nil
        isKept = false
    }
}

struct UserDefaultsCallAppAllowList: CallAppAllowList, @unchecked Sendable {
    private let key = "still.callApps.allowed"
    private let watchingKey = "still.callApps.watching"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var watches: Bool {
        defaults.bool(forKey: watchingKey)
    }

    func setWatching(_ watching: Bool) {
        defaults.set(watching, forKey: watchingKey)
    }

    func apps() -> [CallApp] {
        let allowed = Set(defaults.array(forKey: key) as? [String] ?? [])
        return CallApp.known.map { app in
            CallApp(bundleID: app.bundleID, name: app.name, isAllowed: allowed.contains(app.bundleID))
        }
    }

    func setAllowed(_ allowed: Bool, forBundleID bundleID: String) {
        var current = Set(defaults.array(forKey: key) as? [String] ?? [])
        if allowed {
            current.insert(bundleID)
        } else {
            current.remove(bundleID)
        }
        defaults.set(Array(current), forKey: key)
    }
}
