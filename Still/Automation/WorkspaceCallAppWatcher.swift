#if os(macOS)
import AppKit
import Foundation

@MainActor
final class WorkspaceCallAppWatcher: CallAppWatcher {
    private var observers: [NSObjectProtocol] = []

    func start(
        onActivate: @escaping @MainActor (String) -> Void,
        onDeactivate: @escaping @MainActor (String) -> Void
    ) {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let bundleID = Self.bundleID(in: notification) else { return }
                Task { @MainActor in onActivate(bundleID) }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let bundleID = Self.bundleID(in: notification) else { return }
                Task { @MainActor in onDeactivate(bundleID) }
            },
        ]
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }

    private nonisolated static func bundleID(in notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .bundleIdentifier
    }
}
#endif
