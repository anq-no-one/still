import Foundation
import UserNotifications

/// Tells the user a recording finished processing. The content stays generic
/// on purpose: a notification banner is not the place to quote their speech.
@MainActor
protocol RecordingNotifier: AnyObject {
    func requestAuthorization() async
    func notifyReady(title: String) async
}

@MainActor
final class SystemRecordingNotifier: RecordingNotifier {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyReady(title: String) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Recording ready")
        content.body = title
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "still.recording.ready",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
