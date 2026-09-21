import Foundation
import Observation

enum ProCapability: CaseIterable, Sendable {
    case liveTranscript
    case macSystemAudio
    case automaticRecording
    case speakerSeparation
    case translation
    case generatedNotes
    case semanticSearch
    case synchronization
    case advancedExport
}

enum EntitlementStatus: String, Equatable, Sendable, Codable {
    case free
    case pro
    case pending
}

@MainActor
protocol EntitlementSource: AnyObject {
    func current() async throws -> EntitlementStatus
    func purchase() async throws -> EntitlementStatus
    func restore() async throws -> EntitlementStatus
}

protocol EntitlementCache: Sendable {
    func load() -> EntitlementStatus?
    func save(_ status: EntitlementStatus)
}

/// One place decides what Pro unlocks. Views ask for a capability instead of
/// repeating their own product checks.
@MainActor
@Observable
final class Entitlements {
    private let source: EntitlementSource
    private let cache: EntitlementCache

    private(set) var status: EntitlementStatus
    private(set) var storeUnavailable = false

    init(source: EntitlementSource, cache: EntitlementCache = UserDefaultsEntitlementCache()) {
        self.source = source
        self.cache = cache
        status = cache.load() ?? .free
    }

    var isPro: Bool {
        status == .pro
    }

    func allows(_ capability: ProCapability) -> Bool {
        isPro
    }

    func refresh() async {
        await apply { try await source.current() }
    }

    func purchase() async {
        await apply { try await source.purchase() }
    }

    func restore() async {
        await apply { try await source.restore() }
    }

    /// A store that cannot answer never downgrades a purchase Still already saw,
    /// and never blocks free recording.
    private func apply(_ read: () async throws -> EntitlementStatus) async {
        do {
            let fresh = try await read()
            storeUnavailable = false
            status = fresh
            cache.save(fresh)
        } catch {
            storeUnavailable = true
        }
    }
}

struct UserDefaultsEntitlementCache: EntitlementCache, @unchecked Sendable {
    private let key = "still.entitlement"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> EntitlementStatus? {
        defaults.string(forKey: key).flatMap(EntitlementStatus.init(rawValue:))
    }

    func save(_ status: EntitlementStatus) {
        defaults.set(status.rawValue, forKey: key)
    }
}
