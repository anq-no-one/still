import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

struct MeetingSite: Identifiable, Codable, Equatable, Sendable {
    var id: String { host }

    let host: String
    let name: String
    var isAllowed: Bool

    static let supported: [MeetingSite] = [
        MeetingSite(host: "meet.google.com", name: "Google Meet", isAllowed: false),
        MeetingSite(host: "teams.microsoft.com", name: "Microsoft Teams", isAllowed: false),
        MeetingSite(host: "zoom.us", name: "Zoom", isAllowed: false),
        MeetingSite(host: "whereby.com", name: "Whereby", isAllowed: false),
    ]

    func matches(_ pageHost: String) -> Bool {
        pageHost == host || pageHost.hasSuffix("." + host)
    }
}

protocol MeetingSiteAllowList: Sendable {
    func sites() -> [MeetingSite]
    func setAllowed(_ allowed: Bool, forHost host: String)
    var suggestsSpeakerNames: Bool { get nonmutating set }
}

@MainActor
@Observable
final class BrowserMeetingBridge {
    private let coordinator: RecordingCoordinator
    private let allowList: MeetingSiteAllowList
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private(set) var activeMeetingID: String?
    private(set) var activeBrowser: String?

    init(coordinator: RecordingCoordinator, allowList: MeetingSiteAllowList) {
        self.coordinator = coordinator
        self.allowList = allowList
        suggestsSpeakerNames = allowList.suggestsSpeakerNames
    }

    var sites: [MeetingSite] {
        allowList.sites()
    }

    func setAllowed(_ allowed: Bool, for site: MeetingSite) {
        allowList.setAllowed(allowed, forHost: site.host)
    }

    var suggestsSpeakerNames: Bool {
        didSet { allowList.suggestsSpeakerNames = suggestsSpeakerNames }
    }

    func handle(_ event: BrowserMeetingEvent) async {
        guard isAllowed(event.host) else { return }

        switch event.phase {
        case .started:
            guard activeMeetingID == nil, !coordinator.isRecording else { return }
            activeMeetingID = event.meetingID
            activeBrowser = event.browserBundleID
            await coordinator.start(capturing: .browser(event.browserBundleID))
        case .ended:
            guard activeMeetingID == event.meetingID else { return }
            await endActiveMeeting()
        case .mediaStarted, .mediaEnded:
            guard activeMeetingID == event.meetingID else { return }
            if event.phase == .mediaStarted {
                coordinator.otherMediaStarted()
            } else {
                coordinator.otherMediaEnded()
            }
        case .speakerStarted, .speakerEnded:
            guard suggestsSpeakerNames,
                  let speaker = event.speaker, activeMeetingID == nil || activeMeetingID == event.meetingID else { return }
            if event.phase == .speakerStarted {
                coordinator.speakerStarted(speaker)
            } else {
                coordinator.speakerEnded(speaker)
            }
        }
    }

    func browserQuit(_ bundleID: String) async {
        guard activeMeetingID != nil, activeBrowser == nil || activeBrowser == bundleID else { return }
        await endActiveMeeting()
    }

    private func endActiveMeeting() async {
        activeMeetingID = nil
        activeBrowser = nil
        await coordinator.stopAndSave()
    }

    private func isAllowed(_ host: String) -> Bool {
        allowList.sites().contains { $0.isAllowed && $0.matches(host) }
    }
}

#if os(macOS)
extension BrowserMeetingBridge {
    func listenForExtensions() {
        guard observers.isEmpty else { return }

        let distributed = DistributedNotificationCenter.default()
        let signal = distributed.addObserver(forName: BrowserMeetingSignal.name, object: nil, queue: .main) { [weak self] notification in
            let event = BrowserMeetingSignal.event(fromPayload: notification.object)
            MainActor.assumeIsolated {
                guard let self, let event else { return }
                Task { await self.handle(event) }
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let quit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundleID, WebBrowser.all.contains(where: { $0.bundleID == bundleID }) else { return }
                Task { await self.browserQuit(bundleID) }
            }
        }

        observers = [(distributed, signal), (workspace, quit)]
    }
}
#endif

struct UserDefaultsMeetingSiteAllowList: MeetingSiteAllowList, @unchecked Sendable {
    private let key = "still.meetingSites.allowed"
    private let speakerNamesKey = "still.meetingSites.speakerNames"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func sites() -> [MeetingSite] {
        let allowed = Set(defaults.array(forKey: key) as? [String] ?? [])
        return MeetingSite.supported.map { site in
            MeetingSite(host: site.host, name: site.name, isAllowed: allowed.contains(site.host))
        }
    }

    func setAllowed(_ allowed: Bool, forHost host: String) {
        var current = Set(defaults.array(forKey: key) as? [String] ?? [])
        if allowed {
            current.insert(host)
        } else {
            current.remove(host)
        }
        defaults.set(Array(current), forKey: key)
    }

    var suggestsSpeakerNames: Bool {
        get { defaults.bool(forKey: speakerNamesKey) }
        nonmutating set { defaults.set(newValue, forKey: speakerNamesKey) }
    }
}
