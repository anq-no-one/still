import Foundation

struct AudioProcessActivity: Equatable, Sendable {
    let bundleID: String
    let usesMicrophone: Bool
    let playsAudio: Bool
}

struct CallDetector {
    enum Event: Equatable, Sendable {
        case started(String)
        case ended(String)
    }

    static let defaultReleaseGrace: TimeInterval = 5

    private let apps: [CallApp]
    private let releaseGrace: TimeInterval
    private var microphoneLastHeld: [String: Date] = [:]

    init(apps: [CallApp] = CallApp.known, releaseGrace: TimeInterval = Self.defaultReleaseGrace) {
        self.apps = apps
        self.releaseGrace = releaseGrace
    }

    var activeCalls: Set<String> {
        Set(microphoneLastHeld.keys)
    }

    mutating func observe(_ activity: [AudioProcessActivity], at now: Date) -> [Event] {
        var holdingMicrophone = Set<String>()
        var playingAudio = Set<String>()

        for process in activity {
            guard let owner = apps.first(where: { $0.owns(process.bundleID) })?.bundleID else { continue }
            if process.usesMicrophone { holdingMicrophone.insert(owner) }
            if process.playsAudio { playingAudio.insert(owner) }
        }

        var events: [Event] = []

        for owner in holdingMicrophone.sorted() {
            if microphoneLastHeld[owner] != nil {
                microphoneLastHeld[owner] = now
            } else if playingAudio.contains(owner) {
                microphoneLastHeld[owner] = now
                events.append(.started(owner))
            }
        }

        for (owner, lastHeld) in microphoneLastHeld.sorted(by: { $0.key < $1.key })
        where !holdingMicrophone.contains(owner) && now.timeIntervalSince(lastHeld) >= releaseGrace {
            microphoneLastHeld[owner] = nil
            events.append(.ended(owner))
        }

        return events
    }

    mutating func reset() {
        microphoneLastHeld.removeAll()
    }
}
