#if os(macOS)
import AppKit
import SwiftUI

enum QuitOrigin: Equatable, Sendable {
    case inApp
    case dock
    case menuBar
    case system
    case otherApp

    static let dockBundleID = "com.apple.dock"

    init(event: NSAppleEventDescriptor?, senderBundleID: String?) {
        guard let event else {
            self = .inApp
            return
        }
        if event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            self = .system
        } else if senderBundleID == Self.dockBundleID {
            self = .dock
        } else {
            self = .otherApp
        }
    }
}

enum BackgroundNoticeChoice: Sendable {
    case keepRunning
    case quitCompletely
}

@MainActor
protocol AppShell: AnyObject {
    var hasVisibleWindows: Bool { get }
    func closeWindows()
    func setDockIconVisible(_ visible: Bool)
    func terminate()
    func showBackgroundNotice() -> BackgroundNoticeChoice
}

@MainActor
final class BackgroundPresence: NSObject, NSApplicationDelegate {
    static let noticeShownKey = "still.background.noticeShown"

    var open: (() -> Void)?

    private let shell: AppShell
    private let defaults: UserDefaults
    private var quitConfirmed = false
    private var observers: [NSObjectProtocol] = []

    init(shell: AppShell, defaults: UserDefaults) {
        self.shell = shell
        self.defaults = defaults
    }

    override convenience init() {
        self.init(shell: SystemAppShell(), defaults: .standard)
    }

    func quitCompletely() {
        quitConfirmed = true
        shell.terminate()
    }

    func reply(to origin: QuitOrigin) -> NSApplication.TerminateReply {
        switch origin {
        case .menuBar, .system, .otherApp:
            return .terminateNow
        case .inApp where quitConfirmed:
            return .terminateNow
        case .inApp, .dock:
            if !defaults.bool(forKey: Self.noticeShownKey) {
                defaults.set(true, forKey: Self.noticeShownKey)
                if shell.showBackgroundNotice() == .quitCompletely {
                    quitConfirmed = true
                    return .terminateNow
                }
            }
            hide()
            return .terminateCancel
        }
    }

    func windowsChanged() {
        shell.setDockIconVisible(shell.hasVisibleWindows)
    }

    func finishedLaunching(asLoginItem: Bool) {
        if asLoginItem {
            hide()
        }
    }

    private func hide() {
        shell.closeWindows()
        shell.setDockIconVisible(false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let senderPID = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        let senderBundleID = senderPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        return reply(to: QuitOrigin(event: event, senderBundleID: senderBundleID))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            open?()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let asLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.windowsChanged() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: refresh),
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main, using: refresh),
        ]
        DispatchQueue.main.async { [weak self] in
            self?.finishedLaunching(asLoginItem: asLoginItem)
        }
    }
}

@MainActor
final class SystemAppShell: AppShell {
    var hasVisibleWindows: Bool {
        NSApp.windows.contains(where: Self.isDocumentWindow)
    }

    func closeWindows() {
        NSApp.windows.filter(Self.isDocumentWindow).forEach { $0.close() }
    }

    func setDockIconVisible(_ visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if visible {
            NSApp.activate()
        }
    }

    func terminate() {
        NSApp.terminate(nil)
    }

    func showBackgroundNotice() -> BackgroundNoticeChoice {
        let alert = NSAlert()
        alert.messageText = String(localized: "Still keeps running in the menu bar")
        alert.informativeText = String(
            localized: "Still keeps watching for meetings and records them in the background. To stop it completely, choose Quit Still in the menu bar."
        )
        alert.addButton(withTitle: String(localized: "Keep Running"))
        alert.addButton(withTitle: String(localized: "Quit Completely"))
        return alert.runModal() == .alertSecondButtonReturn ? .quitCompletely : .keepRunning
    }

    private static func isDocumentWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
            && window.className != "NSStatusBarWindow"
    }
}

enum LaunchAtLoginDefault {
    static let appliedKey = "still.loginItem.defaultApplied"

    @MainActor
    static func apply(to login: LaunchAtLogin, setupComplete: Bool, defaults: UserDefaults = .standard) {
        guard setupComplete, !defaults.bool(forKey: appliedKey) else { return }
        defaults.set(true, forKey: appliedKey)
        if !login.isEnabled {
            login.set(true)
        }
    }
}

struct LibraryWindowOpenerInstaller: ViewModifier {
    let presence: BackgroundPresence
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            presence.open = { openWindow(id: StillApp.libraryWindowID) }
        }
    }
}
#endif
