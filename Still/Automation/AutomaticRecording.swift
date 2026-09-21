import Foundation
import Observation

struct CallApp: Identifiable, Codable, Equatable, Sendable {
    var id: String { bundleID }

    let bundleID: String
    let name: String
    var isAllowed: Bool

    static let known: [CallApp] = [
        CallApp(bundleID: "us.zoom.xos", name: "Zoom", isAllowed: false),
        CallApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", isAllowed: false),
        CallApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex", isAllowed: false),
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isAllowed: false),
        CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime", isAllowed: false),
    ]
}

protocol CallAppAllowList: Sendable {
    func apps() -> [CallApp]
    func setAllowed(_ allowed: Bool, forBundleID bundleID: String)
}

@MainActor
protocol CallAppWatcher: AnyObject {
    func start(onActivate: @escaping @MainActor (String) -> Void, onDeactivate: @escaping @MainActor (String) -> Void)
    func stop()
}

/// Starts a Recording when an app the user explicitly allowed comes forward.
/// One activation means one Recording: coming back to the same app while it is
/// still recording changes nothing, and an app the user switches off never
/// starts another.
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
                self?.appWentAway(bundleID)
            }
        )
        isWatching = true
    }

    func stopWatching() {
        watcher.stop()
        isWatching = false
    }

    func setAllowed(_ allowed: Bool, for app: CallApp) {
        allowList.setAllowed(allowed, forBundleID: app.bundleID)

        if !allowed, triggeredBy == app.bundleID {
            triggeredBy = nil
        }
    }

    /// A recording that should never have started leaves nothing behind.
    func discardAutomaticRecording() async {
        await coordinator.cancel()
        triggeredBy = nil
    }

    private func appBecameActive(_ bundleID: String) async {
        guard isWatching,
              triggeredBy == nil,
              !coordinator.isRecording,
              allowList.apps().contains(where: { $0.bundleID == bundleID && $0.isAllowed })
        else { return }

        triggeredBy = bundleID
        await coordinator.start()
    }

    private func appWentAway(_ bundleID: String) {
        guard triggeredBy == bundleID else { return }
        triggeredBy = nil
    }
}

struct UserDefaultsCallAppAllowList: CallAppAllowList, @unchecked Sendable {
    private let key = "still.callApps.allowed"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
