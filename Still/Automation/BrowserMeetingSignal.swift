import Foundation

struct BrowserMeetingEvent: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case started
        case ended
        case speakerStarted
        case speakerEnded
        case mediaStarted
        case mediaEnded
        case participants

        var isAboutSpeaker: Bool {
            self == .speakerStarted || self == .speakerEnded
        }
    }

    let host: String
    let meetingID: String
    let phase: Phase
    var browserBundleID: String?
    var tabID: Int?
    var speaker: String?
    var participants: [String]?
}

enum BrowserMeetingSignal {
    static let name = Notification.Name("com.andrii.still.browser.meeting")
    static let maximumHostLength = 253
    static let maximumMeetingIDLength = 512
    static let maximumSpeakerLength = 128
    static let maximumParticipants = 100

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    static func payload(for event: BrowserMeetingEvent) -> String? {
        guard let data = try? JSONEncoder().encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func event(fromPayload payload: Any?) -> BrowserMeetingEvent? {
        guard let text = payload as? String, let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(BrowserMeetingEvent.self, from: data)
        else { return nil }
        return validated(event)
    }

    static func event(fromExtensionMessage data: Data, browserBundleID: String?) -> BrowserMeetingEvent? {
        guard var event = try? JSONDecoder().decode(BrowserMeetingEvent.self, from: data) else { return nil }
        event.browserBundleID = browserBundleID
        return validated(event)
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

    static func speakerName(from text: String) -> String? {
        let visible = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let name = String(String.UnicodeScalarView(visible))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !name.isEmpty, name.count <= maximumSpeakerLength else { return nil }
        return name
    }

    private static func validated(_ event: BrowserMeetingEvent) -> BrowserMeetingEvent? {
        guard isValid(event) else { return nil }

        var validated = event
        validated.participants = nil
        if event.phase == .participants {
            validated.speaker = nil
            let names = (event.participants ?? []).compactMap(speakerName(from:)).prefix(maximumParticipants)
            guard !names.isEmpty else { return nil }
            validated.participants = Array(names)
            return validated
        }
        guard event.phase.isAboutSpeaker else {
            validated.speaker = nil
            return validated
        }
        guard let speaker = event.speaker.flatMap(speakerName(from:)) else { return nil }
        validated.speaker = speaker
        return validated
    }

    private static func isValid(_ event: BrowserMeetingEvent) -> Bool {
        !event.host.isEmpty
            && event.host.count <= maximumHostLength
            && event.host.unicodeScalars.allSatisfy(hostCharacters.contains)
            && !event.meetingID.isEmpty
            && event.meetingID.count <= maximumMeetingIDLength
            && (event.browserBundleID?.count ?? 0) <= 255
    }
}
