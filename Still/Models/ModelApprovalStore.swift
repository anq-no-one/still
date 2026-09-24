import Foundation

protocol ModelApprovalStore: Sendable {
    func isApproved(_ pack: ModelPack) -> Bool
    func markApproved(_ pack: ModelPack)
}

struct UserDefaultsModelApprovalStore: ModelApprovalStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isApproved(_ pack: ModelPack) -> Bool {
        defaults.bool(forKey: key(for: pack))
    }

    func markApproved(_ pack: ModelPack) {
        defaults.set(true, forKey: key(for: pack))
    }

    private func key(for pack: ModelPack) -> String {
        "still.models.approved.\(pack.id).\(pack.version)"
    }
}

final class MemoryModelApprovalStore: ModelApprovalStore, @unchecked Sendable {
    private var approved: Set<String> = []

    func isApproved(_ pack: ModelPack) -> Bool {
        approved.contains(pack.id + pack.version)
    }

    func markApproved(_ pack: ModelPack) {
        approved.insert(pack.id + pack.version)
    }
}
