import Foundation
import Testing
@testable import Still

struct BrowserMeetingSignalTests {
    @Test
    func anEventSurvivesTheTripThroughTheNotification() throws {
        let event = BrowserMeetingEvent(
            host: "meet.google.com",
            meetingID: "meet.google.com/abc-defg-hij",
            phase: .started,
            browserBundleID: "com.google.Chrome",
            tabID: 42
        )

        let payload = try #require(BrowserMeetingSignal.payload(for: event))

        #expect(BrowserMeetingSignal.event(fromPayload: payload) == event)
    }

    @Test
    func aParticipantListArrivesCleaned() throws {
        let message = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"participants","participants":["  Phil   Carter ","","Anna\u0007 Lee"]}"#.utf8)

        let event = try #require(BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: nil))

        #expect(event.participants == ["Phil Carter", "Anna Lee"])
        #expect(event.speaker == nil)
    }

    @Test
    func anEmptyParticipantListIsRefused() {
        let message = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"participants","participants":[]}"#.utf8)

        #expect(BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: nil) == nil)
    }

    @Test
    func aHugeParticipantListIsCapped() throws {
        let names = (1...500).map { "\"Person \($0)\"" }.joined(separator: ",")
        let message = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"participants","participants":["#.utf8 + Data(names.utf8) + Data("]}".utf8))

        let event = try #require(BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: nil))

        #expect(event.participants?.count == BrowserMeetingSignal.maximumParticipants)
    }

    @Test
    func theBrowserNamedByTheSenderReplacesWhatThePageClaims() throws {
        let message = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"ended","browserBundleID":"com.evil"}"#.utf8)

        let event = try #require(BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: "com.brave.Browser"))

        #expect(event.browserBundleID == "com.brave.Browser")
        #expect(event.phase == .ended)
    }

    @Test
    func anUnknownBrowserIsLeftBlank() throws {
        let message = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"started","browserBundleID":"com.evil"}"#.utf8)

        let event = try #require(BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: nil))

        #expect(event.browserBundleID == nil)
    }

    @Test(arguments: [
        #"{"host":"meet.google.com","meetingID":"m","phase":"paused"}"#,
        #"{"host":"","meetingID":"m","phase":"started"}"#,
        #"{"host":"meet.google.com","meetingID":"","phase":"started"}"#,
        #"{"host":"Meet.Google.com/../x","meetingID":"m","phase":"started"}"#,
        #"{"meetingID":"m","phase":"started"}"#,
        #"not json"#,
    ])
    func malformedMessagesAreRefused(_ message: String) {
        #expect(BrowserMeetingSignal.event(fromExtensionMessage: Data(message.utf8), browserBundleID: nil) == nil)
        #expect(BrowserMeetingSignal.event(fromPayload: message) == nil)
    }

    @Test
    func anOversizedMeetingIDIsRefused() {
        let id = String(repeating: "a", count: BrowserMeetingSignal.maximumMeetingIDLength + 1)
        let message = Data(#"{"host":"meet.google.com","meetingID":"\#(id)","phase":"started"}"#.utf8)

        #expect(BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: nil) == nil)
    }

    @Test
    func aPayloadThatIsNotTextIsRefused() {
        #expect(BrowserMeetingSignal.event(fromPayload: nil) == nil)
        #expect(BrowserMeetingSignal.event(fromPayload: 42) == nil)
    }
}
