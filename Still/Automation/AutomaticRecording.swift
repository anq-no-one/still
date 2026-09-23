import Foundation
import Observation

struct CallApp: Identifiable, Codable, Equatable, Sendable {
    var id: String { bundleID }

    let bundleID: String
    let name: String
    var isAllowed: Bool

    static let known: [CallApp] = [
        CallApp(bundleID: "com.google.Chrome", name: "Google Chrome", isAllowed: false),
        CallApp(bundleID: "company.thebrowser.Browser", name: "Arc", isAllowed: false),
        CallApp(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", isAllowed: false),
        CallApp(bundleID: "com.brave.Browser", name: "Brave", isAllowed: false),
        CallApp(bundleID: "org.mozilla.firefox", name: "Firefox", isAllowed: false),
        CallApp(bundleID: "us.zoom.xos", name: "Zoom", isAllowed: false),
        CallApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", isAllowed: false),
        CallApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex", isAllowed: false),
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isAllowed: false),
        CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime", isAllowed: false),
        CallApp(bundleID: "ru.keepcoder.Telegram", name: "Telegram", isAllowed: false),
        CallApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", isAllowed: false),
        CallApp(bundleID: "com.hnc.Discord", name: "Discord", isAllowed: false),
    ]

    func owns(_ processBundleID: String) -> Bool {
        processBundleID == bundleID || processBundleID.hasPrefix(bundleID + ".")
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
    private let coordinator: RecordingCoordinator
    private let watcher: CallAppWatcher
    private let allowList: CallAppAllowList

    private(set) var isWatching = false
    private(set) var triggeredBy: String?

    init(coordinator: RecordingCoordinator, watcher: CallAppWatcher, allowList: CallAppAllowList) {
        self.coordinator = coordinator
        self.watcher = watcher
        self.allowList = allowList
        if allowList.watches {
            startWatching()
        }
    }

    var apps: [CallApp] {
        allowList.apps()
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

    func setAllowed(_ allowed: Bool, for app: CallApp) {
        allowList.setAllowed(allowed, forBundleID: app.bundleID)

        if !allowed, triggeredBy == app.bundleID {
            triggeredBy = nil
        }
    }

    func discardAutomaticRecording() async {
        await coordinator.cancel()
        triggeredBy = nil
    }

    private func appBecameActive(_ processBundleID: String) async {
        guard isWatching,
              triggeredBy == nil,
              !coordinator.isRecording,
              let app = allowList.apps().first(where: { $0.isAllowed && $0.owns(processBundleID) })
        else { return }

        triggeredBy = app.bundleID
        await coordinator.start()
    }

    private func appWentAway(_ processBundleID: String) async {
        guard let triggeredBy, CallApp(bundleID: triggeredBy, name: "", isAllowed: true).owns(processBundleID) else { return }

        self.triggeredBy = nil
        if coordinator.isRecording {
            await coordinator.stopAndSave()
        }
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
