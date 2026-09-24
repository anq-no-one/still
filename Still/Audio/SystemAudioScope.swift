import Foundation
import Observation

enum SystemAudioScope: Equatable, Sendable {
    case callApps
    case apps(Set<String>)

    static func app(_ app: CallApp) -> Self {
        .apps(Set(app.processBundleIDs))
    }

    static func browser(_ bundleID: String?) -> Self {
        .apps(bundleID.map { [$0] } ?? Set(WebBrowser.all.map(\.bundleID)))
    }

    var bundleIDs: Set<String> {
        switch self {
        case .callApps: Set(CallApp.known.flatMap(\.processBundleIDs) + WebBrowser.all.map(\.bundleID))
        case .apps(let bundleIDs): bundleIDs
        }
    }

    func includes(_ processBundleID: String) -> Bool {
        bundleIDs.contains { processBundleID == $0 || processBundleID.hasPrefix($0 + ".") }
    }
}

@MainActor
@Observable
final class SystemAudioTarget {
    var scope: SystemAudioScope = .callApps
}
