import Foundation
import Observation

enum OwnerAuthenticationResult: Equatable, Sendable {
    case success
    case cancelled
    case failed(String)
    case unavailable(String)
}

@MainActor
protocol OwnerAuthenticator {
    func authenticate(reason: String) async -> OwnerAuthenticationResult
}

protocol AppLockSettingsStore: Sendable {
    var isEnabled: Bool { get nonmutating set }
    var timeout: TimeInterval { get nonmutating set }
}

@MainActor
@Observable
final class AppLock {
    nonisolated static let defaultTimeout: TimeInterval = 5 * 60
    static let timeoutChoices: [TimeInterval] = [0, 60, 5 * 60, 15 * 60, 60 * 60]

    private let settings: AppLockSettingsStore
    private let authenticator: OwnerAuthenticator
    private let now: () -> Date

    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var problem: OwnerAuthenticationResult?
    private var leftAt: Date?

    init(settings: AppLockSettingsStore, authenticator: OwnerAuthenticator, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.authenticator = authenticator
        self.now = now
        isLocked = settings.isEnabled
    }

    var isEnabled: Bool {
        settings.isEnabled
    }

    var timeout: TimeInterval {
        get { settings.timeout }
        set { settings.timeout = newValue }
    }

    func enable() async -> OwnerAuthenticationResult {
        let result = await authenticator.authenticate(reason: String(localized: "Turn on the lock for your recordings."))
        if result == .success {
            settings.isEnabled = true
        }
        return result
    }

    func disable() {
        settings.isEnabled = false
        isLocked = false
        leftAt = nil
    }

    func didLeave() {
        guard settings.isEnabled, !isLocked, leftAt == nil else { return }
        leftAt = now()
    }

    func didReturn() {
        defer { leftAt = nil }
        guard settings.isEnabled, let leftAt else { return }
        if now().timeIntervalSince(leftAt) >= settings.timeout {
            isLocked = true
        }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let result = await authenticator.authenticate(reason: String(localized: "Unlock your recordings."))
        if result == .success {
            isLocked = false
            problem = nil
        } else {
            problem = result
        }
    }
}

struct UserDefaultsAppLockSettings: AppLockSettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: "still.lock.enabled") }
        nonmutating set { defaults.set(newValue, forKey: "still.lock.enabled") }
    }

    var timeout: TimeInterval {
        get { defaults.object(forKey: "still.lock.timeout") as? TimeInterval ?? AppLock.defaultTimeout }
        nonmutating set { defaults.set(newValue, forKey: "still.lock.timeout") }
    }
}
