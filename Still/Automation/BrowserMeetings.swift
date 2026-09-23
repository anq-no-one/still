import Foundation
import Observation

struct MeetingSite: Identifiable, Codable, Equatable, Sendable {
    var id: String { host }

    let host: String
    let name: String
    var isAllowed: Bool

    /// The only hosts the extension may ever see. Anything else is refused
    /// before it reaches Still.
    static let supported: [MeetingSite] = [
        MeetingSite(host: "meet.google.com", name: "Google Meet", isAllowed: false),
        MeetingSite(host: "teams.microsoft.com", name: "Microsoft Teams", isAllowed: false),
        MeetingSite(host: "zoom.us", name: "Zoom", isAllowed: false),
        MeetingSite(host: "whereby.com", name: "Whereby", isAllowed: false),
    ]
}

struct BrowserMeetingEvent: Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case started
        case ended
    }

    let host: String
    let meetingID: String
    let phase: Phase
}

protocol MeetingSiteAllowList: Sendable {
    func sites() -> [MeetingSite]
    func setAllowed(_ allowed: Bool, forHost host: String)
}

/// Receives nothing but a host, a meeting id, and whether it started or ended.
/// The browser never sees a transcript, a note, audio, or a key, because none
/// of that travels in this direction.
@MainActor
@Observable
final class BrowserMeetingBridge {
    private let coordinator: RecordingCoordinator
    private let allowList: MeetingSiteAllowList

    private(set) var activeMeetingID: String?

    init(coordinator: RecordingCoordinator, allowList: MeetingSiteAllowList) {
        self.coordinator = coordinator
        self.allowList = allowList
    }

    var sites: [MeetingSite] {
        allowList.sites()
    }

    func setAllowed(_ allowed: Bool, for site: MeetingSite) {
        allowList.setAllowed(allowed, forHost: site.host)
    }

    func handle(_ event: BrowserMeetingEvent) async {
        guard isAllowed(event.host) else { return }

        switch event.phase {
        case .started:
            guard activeMeetingID == nil, !coordinator.isRecording else { return }
            activeMeetingID = event.meetingID
            await coordinator.start(capturing: .browser(nil))
        case .ended:
            guard activeMeetingID == event.meetingID else { return }
            activeMeetingID = nil
            await coordinator.stopAndSave()
        }
    }

    private func isAllowed(_ host: String) -> Bool {
        allowList.sites().contains { $0.host == host && $0.isAllowed }
    }
}

struct UserDefaultsMeetingSiteAllowList: MeetingSiteAllowList, @unchecked Sendable {
    private let key = "still.meetingSites.allowed"
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
}
