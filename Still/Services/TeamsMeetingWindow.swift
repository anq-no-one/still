import CoreGraphics
import Foundation

struct MeetingWindowInfo: Equatable, Sendable {
    let id: UInt32
    let appBundleID: String
    let title: String?
    let frame: CGRect
    let isOnScreen: Bool

    var area: CGFloat {
        frame.width * frame.height
    }
}

enum MeetingWindowResolution: Equatable, Sendable {
    case window(MeetingWindowInfo)
    case teamsApp
}

enum TeamsMeetingWindow {
    static let teamsBundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]
    static let inconclusiveAreaShare: CGFloat = 0.8

    static func resolve(from windows: [MeetingWindowInfo]) -> MeetingWindowResolution? {
        let teams = windows.filter { teamsBundleIDs.contains($0.appBundleID) && $0.isOnScreen }
        guard !teams.isEmpty else { return nil }
        guard let meeting = pickMeeting(from: teams) else { return .teamsApp }
        return .window(meeting)
    }

    static func pickMeeting(from windows: [MeetingWindowInfo]) -> MeetingWindowInfo? {
        let titled = windows.filter { !($0.title?.isEmpty ?? true) }
        let candidates = titled.isEmpty ? windows : titled
        let ranked = candidates.sorted { $0.area > $1.area }
        guard let largest = ranked.first else { return nil }
        guard largest.area > 0 else { return nil }
        if ranked.count > 1, ranked[1].area >= inconclusiveAreaShare * largest.area {
            return nil
        }
        return largest
    }
}

#if os(macOS)
import AppKit
import ScreenCaptureKit

extension TeamsMeetingWindow {
    @MainActor
    static func processIdentifiers() -> [Int32] {
        teamsBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) }
    }

    static func fetchWindows() async throws -> [MeetingWindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.windows.map { window in
            MeetingWindowInfo(
                id: window.windowID,
                appBundleID: window.owningApplication?.bundleIdentifier ?? "",
                title: window.title,
                frame: window.frame,
                isOnScreen: window.isOnScreen
            )
        }
    }

    static func filter(
        for resolution: MeetingWindowResolution,
        in content: SCShareableContent
    ) -> SCContentFilter? {
        switch resolution {
        case .window(let info):
            guard let window = content.windows.first(where: { $0.windowID == info.id }) else { return nil }
            return SCContentFilter(desktopIndependentWindow: window)
        case .teamsApp:
            guard let display = content.displays.first else { return nil }
            let apps = content.applications.filter { teamsBundleIDs.contains($0.bundleIdentifier) }
            guard !apps.isEmpty else { return nil }
            return SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }
    }
}
#endif
