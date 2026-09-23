import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    static let safariBundleID = "com.apple.Safari"

    func beginRequest(with context: NSExtensionContext) {
        if let item = context.inputItems.first as? NSExtensionItem,
           let message = item.userInfo?[SFExtensionMessageKey],
           JSONSerialization.isValidJSONObject(message),
           let data = try? JSONSerialization.data(withJSONObject: message),
           let event = BrowserMeetingSignal.event(fromExtensionMessage: data, browserBundleID: Self.safariBundleID) {
            BrowserMeetingSignal.post(event)
        }

        context.completeRequest(returningItems: nil)
    }
}
