import Foundation

/// Every long-lived part of the app says what it is doing right now, so a
/// bundle or a marker shows the whole app's state at one instant: the
/// recording phase next to sync, models, call detection and permissions.
@MainActor
final class DebugStateRegistry {
    private var providers: [String: @MainActor () -> [String: String]] = [:]

    func register(_ name: String, _ provider: @escaping @MainActor () -> [String: String]) {
        providers[name] = provider
    }

    func snapshot() -> [String: [String: String]] {
        providers.mapValues { $0() }
    }
}
