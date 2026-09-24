import Foundation
import Testing
@testable import Still

@MainActor
struct AppLockTests {
    @Test
    func staysOffForExistingAndNewUsers() {
        let lock = AppLock(settings: MemoryAppLockSettings(), authenticator: FakeOwnerAuthenticator())

        #expect(!lock.isEnabled)
        #expect(!lock.isLocked)
        #expect(lock.timeout == AppLock.defaultTimeout)
    }

    @Test
    func turningTheLockOnNeedsTheOwner() async {
        let settings = MemoryAppLockSettings()
        let authenticator = FakeOwnerAuthenticator(answers: [.cancelled, .success])
        let lock = AppLock(settings: settings, authenticator: authenticator)

        #expect(await lock.enable() == .cancelled)
        #expect(!lock.isEnabled)

        #expect(await lock.enable() == .success)
        #expect(lock.isEnabled)
        #expect(!lock.isLocked)
    }

    @Test
    func aFreshLaunchLocksOnceAndUnlocksWithTheOwner() async {
        let settings = MemoryAppLockSettings(isEnabled: true)
        let authenticator = FakeOwnerAuthenticator(answers: [.success])
        let lock = AppLock(settings: settings, authenticator: authenticator)
        #expect(lock.isLocked)

        await lock.unlock()
        await lock.unlock()

        #expect(!lock.isLocked)
        #expect(authenticator.requests == 1)
    }

    @Test
    func locksOnlyAfterTheChosenTimeAway() async {
        var clock = Date(timeIntervalSince1970: 0)
        let settings = MemoryAppLockSettings(isEnabled: true)
        let lock = AppLock(settings: settings, authenticator: FakeOwnerAuthenticator(answers: [.success]), now: { clock })
        await lock.unlock()

        lock.didLeave()
        clock += AppLock.defaultTimeout - 1
        lock.didReturn()
        #expect(!lock.isLocked)

        lock.didLeave()
        clock += AppLock.defaultTimeout
        lock.didReturn()
        #expect(lock.isLocked)
    }

    @Test
    func continuousUseNeverLocks() async {
        var clock = Date(timeIntervalSince1970: 0)
        let lock = AppLock(
            settings: MemoryAppLockSettings(isEnabled: true),
            authenticator: FakeOwnerAuthenticator(answers: [.success]),
            now: { clock }
        )
        await lock.unlock()

        clock += 24 * 60 * 60
        lock.didReturn()

        #expect(!lock.isLocked)
    }

    @Test
    func aFailedOrUnavailableCheckKeepsTheLibraryHidden() async {
        let authenticator = FakeOwnerAuthenticator(answers: [.failed("Face ID failed"), .unavailable("No passcode")])
        let lock = AppLock(settings: MemoryAppLockSettings(isEnabled: true), authenticator: authenticator)

        await lock.unlock()
        #expect(lock.isLocked)
        #expect(lock.problem == .failed("Face ID failed"))

        await lock.unlock()
        #expect(lock.isLocked)
        #expect(lock.problem == .unavailable("No passcode"))
    }

    @Test
    func turningTheLockOffUnlocksWithoutAPrompt() {
        let authenticator = FakeOwnerAuthenticator()
        let lock = AppLock(settings: MemoryAppLockSettings(isEnabled: true), authenticator: authenticator)

        lock.disable()

        #expect(!lock.isLocked)
        #expect(!lock.isEnabled)
        #expect(authenticator.requests == 0)
    }
}

final class MemoryAppLockSettings: AppLockSettingsStore, @unchecked Sendable {
    var isEnabled: Bool
    var timeout: TimeInterval

    init(isEnabled: Bool = false, timeout: TimeInterval = AppLock.defaultTimeout) {
        self.isEnabled = isEnabled
        self.timeout = timeout
    }
}

@MainActor
final class FakeOwnerAuthenticator: OwnerAuthenticator {
    private var answers: [OwnerAuthenticationResult]
    private(set) var requests = 0

    init(answers: [OwnerAuthenticationResult] = []) {
        self.answers = answers
    }

    func authenticate(reason: String) async -> OwnerAuthenticationResult {
        requests += 1
        return answers.isEmpty ? .cancelled : answers.removeFirst()
    }
}
