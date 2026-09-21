import Foundation
import SafariServices

/// Hands the meeting signal to Still and answers nothing. The extension is a
/// one-way sensor, so there is no path back out of the Library.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    static let messageName = Notification.Name("still.browser.meeting")

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any],
              let host = message["host"] as? String,
              let meetingID = message["meetingID"] as? String,
              let phase = message["phase"] as? String
        else {
            context.completeRequest(returningItems: nil)
            return
        }

        DistributedNotificationCenter.default().postNotificationName(
            Self.messageName,
            object: nil,
            userInfo: ["host": host, "meetingID": meetingID, "phase": phase],
            deliverImmediately: true
        )

        context.completeRequest(returningItems: nil)
    }
}
