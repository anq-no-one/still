#if os(macOS)
import AppKit
import Testing
@testable import Still

@MainActor
struct BackgroundPresenceTests {
    @Test
    func quittingFromTheDockHidesStillAndKeepsItRunning() {
        let shell = FakeAppShell()
        let presence = BackgroundPresence(shell: shell, defaults: freshDefaults())

        let reply = presence.reply(to: .dock)

        #expect(reply == .terminateCancel)
        #expect(shell.closedWindows)
        #expect(shell.dockIconVisible == false)
    }

    @Test
    func commandQKeepsStillRunningInTheMenuBar() {
        let shell = FakeAppShell()
        let presence = BackgroundPresence(shell: shell, defaults: freshDefaults())

        #expect(presence.reply(to: .inApp) == .terminateCancel)
        #expect(shell.dockIconVisible == false)
    }

    @Test
    func quitStillInTheMenuBarReallyQuits() {
        let shell = FakeAppShell()
        let presence = BackgroundPresence(shell: shell, defaults: freshDefaults())

        presence.quitCompletely()

        #expect(shell.terminateRequested)
        #expect(presence.reply(to: .inApp) == .terminateNow)
    }

    @Test(arguments: [QuitOrigin.system, .otherApp])
    func logoutShutdownAndUpdatersQuitNormally(origin: QuitOrigin) {
        let shell = FakeAppShell()
        let presence = BackgroundPresence(shell: shell, defaults: freshDefaults())

        #expect(presence.reply(to: origin) == .terminateNow)
        #expect(!shell.closedWindows)
    }

    @Test
    func theFirstHideExplainsItselfOnlyOnce() {
        let shell = FakeAppShell()
        let presence = BackgroundPresence(shell: shell, defaults: freshDefaults())

        _ = presence.reply(to: .dock)
        _ = presence.reply(to: .dock)

        #expect(shell.noticesShown == 1)
    }

    @Test
    func choosingQuitCompletelyInTheFirstHideNoticeQuits() {
        let shell = FakeAppShell()
        shell.noticeChoice = .quitCompletely
        let presence = BackgroundPresence(shell: shell, defaults: freshDefaults())

        #expect(presence.reply(to: .dock) == .terminateNow)
        #expect(!shell.closedWindows)
    }

    @Test
    func closingTheLastWindowNeverQuits() {
        let presence = BackgroundPresence(shell: FakeAppShell(), defaults: freshDefaults())

        #expect(!presence.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test
    func theDockIconFollowsTheVisibleWindows() {
        let shell = FakeAppShell()
        let presence = BackgroundPresence(shell: shell, defaults: freshDefaults())

        shell.hasVisibleWindows = false
        presence.windowsChanged()
        #expect(shell.dockIconVisible == false)

        shell.hasVisibleWindows = true
        presence.windowsChanged()
        #expect(shell.dockIconVisible == true)
    }

    @Test
    func aLoginLaunchStaysInTheBackground() {
        let shell = FakeAppShell()
        let presence = BackgroundPresence(shell: shell, defaults: freshDefaults())

        presence.finishedLaunching(asLoginItem: true)

        #expect(shell.closedWindows)
        #expect(shell.dockIconVisible == false)
    }

    @Test
    func aNormalLaunchShowsTheLibrary() {
        let shell = FakeAppShell()
        let presence = BackgroundPresence(shell: shell, defaults: freshDefaults())

        presence.finishedLaunching(asLoginItem: false)

        #expect(!shell.closedWindows)
    }

    @Test
    func clickingTheDockIconWithNoWindowOpensTheLibrary() {
        let presence = BackgroundPresence(shell: FakeAppShell(), defaults: freshDefaults())
        let opened = Flag()
        presence.open = { opened.raise() }

        _ = presence.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        #expect(opened.isRaised)
    }

    @Test
    func clickingTheDockIconWithAWindowLeavesItAlone() {
        let presence = BackgroundPresence(shell: FakeAppShell(), defaults: freshDefaults())
        let opened = Flag()
        presence.open = { opened.raise() }

        _ = presence.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)

        #expect(!opened.isRaised)
    }

    @Test
    func anInAppQuitHasNoAppleEvent() {
        #expect(QuitOrigin(event: nil, senderBundleID: nil) == .inApp)
    }

    @Test
    func aDockQuitComesFromTheDock() {
        #expect(QuitOrigin(event: quitEvent(), senderBundleID: "com.apple.dock") == .dock)
    }

    @Test
    func aQuitWithAShutdownReasonComesFromTheSystem() {
        let event = quitEvent()
        event.setParam(NSAppleEventDescriptor(enumCode: OSType(kAEShutDown)), forKeyword: AEKeyword(kAEQuitReason))

        #expect(QuitOrigin(event: event, senderBundleID: "com.apple.dock") == .system)
    }

    @Test
    func aQuitFromAnotherAppIsHonored() {
        #expect(QuitOrigin(event: quitEvent(), senderBundleID: "com.apple.appstoreagent") == .otherApp)
    }

    @Test
    func launchAtLoginTurnsOnOnceSetupIsComplete() {
        let service = FakeLoginItem()
        let login = LaunchAtLogin(service: service)
        let defaults = freshDefaults()

        LaunchAtLoginDefault.apply(to: login, setupComplete: false, defaults: defaults)
        #expect(!service.isEnabled)

        LaunchAtLoginDefault.apply(to: login, setupComplete: true, defaults: defaults)
        #expect(service.isEnabled)
    }

    @Test
    func launchAtLoginStaysOffAfterTheUserTurnsItOff() {
        let service = FakeLoginItem()
        let login = LaunchAtLogin(service: service)
        let defaults = freshDefaults()
        LaunchAtLoginDefault.apply(to: login, setupComplete: true, defaults: defaults)

        login.set(false)
        LaunchAtLoginDefault.apply(to: login, setupComplete: true, defaults: defaults)

        #expect(!service.isEnabled)
    }

    private func quitEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEQuitApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "BackgroundPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

@MainActor
private final class FakeAppShell: AppShell {
    var hasVisibleWindows = true
    var closedWindows = false
    var dockIconVisible: Bool?
    var terminateRequested = false
    var noticesShown = 0
    var noticeChoice = BackgroundNoticeChoice.keepRunning

    func closeWindows() {
        closedWindows = true
        hasVisibleWindows = false
    }

    func setDockIconVisible(_ visible: Bool) {
        dockIconVisible = visible
    }

    func terminate() {
        terminateRequested = true
    }

    func showBackgroundNotice() -> BackgroundNoticeChoice {
        noticesShown += 1
        return noticeChoice
    }
}
#endif
