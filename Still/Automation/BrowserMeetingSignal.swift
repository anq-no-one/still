import Foundation

struct BrowserMeetingEvent: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case started
        case ended
    }

    let host: String
    let meetingID: String
    let phase: Phase
    var browserBundleID: String?
    var tabID: Int?
}

enum BrowserMeetingSignal {
    static let name = Notification.Name("com.andrii.still.browser.meeting")
    static let maximumHostLength = 253
    static let maximumMeetingIDLength = 512

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    static func payload(for event: BrowserMeetingEvent) -> String? {
        guard let data = try? JSONEncoder().encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func event(fromPayload payload: Any?) -> BrowserMeetingEvent? {
        guard let text = payload as? String, let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(BrowserMeetingEvent.self, from: data),
              isValid(event)
        else { return nil }
        return event
    }

    static func event(fromExtensionMessage data: Data, browserBundleID: String?) -> BrowserMeetingEvent? {
        guard var event = try? JSONDecoder().decode(BrowserMeetingEvent.self, from: data) else { return nil }
        event.browserBundleID = browserBundleID
        return isValid(event) ? event : nil
    }

    #if os(macOS)
    static func post(_ event: BrowserMeetingEvent) {
        guard let payload = payload(for: event) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: payload,
            userInfo: nil,
            deliverImmediately: true
        )
    }
    #endif

    private static func isValid(_ event: BrowserMeetingEvent) -> Bool {
        !event.host.isEmpty
            && event.host.count <= maximumHostLength
            && event.host.unicodeScalars.allSatisfy(hostCharacters.contains)
            && !event.meetingID.isEmpty
            && event.meetingID.count <= maximumMeetingIDLength
            && (event.browserBundleID?.count ?? 0) <= 255
    }
}
