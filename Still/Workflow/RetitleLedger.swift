import Foundation

protocol RetitleLedger: AnyObject {
    func isDone(_ id: UUID, tier: String) -> Bool
    func markDone(_ id: UUID, tier: String)
}

final class MemoryRetitleLedger: RetitleLedger {
    private var done: Set<String> = []

    func isDone(_ id: UUID, tier: String) -> Bool {
        done.contains("\(tier)/\(id)")
    }

    func markDone(_ id: UUID, tier: String) {
        done.insert("\(tier)/\(id)")
    }
}

final class UserDefaultsRetitleLedger: RetitleLedger {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isDone(_ id: UUID, tier: String) -> Bool {
        (defaults.stringArray(forKey: key(tier)) ?? []).contains(id.uuidString)
    }

    func markDone(_ id: UUID, tier: String) {
        var done = defaults.stringArray(forKey: key(tier)) ?? []
        done.append(id.uuidString)
        defaults.set(done, forKey: key(tier))
    }

    private func key(_ tier: String) -> String {
        "still.retitle.\(tier)"
    }
}
