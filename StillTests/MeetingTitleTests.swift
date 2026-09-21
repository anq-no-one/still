import Foundation
import Testing
@testable import Still

struct MeetingTitleTests {
    @Test
    func usesFirstSevenWords() {
        let title = MeetingTitle.from(transcript: "One two three four five six seven eight nine")

        #expect(title == "One two three four five six seven")
    }

    @Test
    func trimsLongTitle() {
        let title = MeetingTitle.from(
            transcript: "Extraordinarily long introductory wording makes this title exceed its limit"
        )

        #expect(title.count == 50)
        #expect(title.hasSuffix("…"))
    }

    @Test
    func fallsBackToDateForEmptyTranscript() {
        let locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 0)

        let title = MeetingTitle.from(transcript: "   ", date: date, calendar: calendar)

        #expect(!title.isEmpty)
    }
}

