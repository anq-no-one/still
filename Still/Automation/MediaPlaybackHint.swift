#if os(macOS)
import Foundation
import Observation

@MainActor
@Observable
final class MediaPlaybackHint {
    private let source: AudioActivitySource
    private let settings: UserDefaults
    private let ownBundleID: String
    private let ignoredKey = "still.mediaHint.off"

    private(set) var playingBundleIDs: [String] = []

    init(source: AudioActivitySource, settings: UserDefaults = .standard, ownBundleID: String = Bundle.main.bundleIdentifier ?? "") {
        self.source = source
        self.settings = settings
        self.ownBundleID = ownBundleID
    }

    var isOff: Bool {
        settings.bool(forKey: ignoredKey)
    }

    func check(ignoring callApp: String? = nil) {
        guard !isOff else {
            playingBundleIDs = []
            return
        }

        playingBundleIDs = source.currentActivity()
            .filter { $0.playsAudio && !$0.usesMicrophone }
            .map(\.bundleID)
            .filter { !$0.hasPrefix(ownBundleID) && CallApp.owner(of: $0) == nil }
            .filter { bundleID in callApp.map { !bundleID.hasPrefix($0) } ?? true }
            .reduce(into: []) { unique, id in if !unique.contains(id) { unique.append(id) } }
    }

    func dismiss() {
        playingBundleIDs = []
    }

    func turnOff() {
        settings.set(true, forKey: ignoredKey)
        playingBundleIDs = []
    }

    func turnOn() {
        settings.set(false, forKey: ignoredKey)
    }
}
#endif
