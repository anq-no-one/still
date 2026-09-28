import Foundation

enum RecordingTitle {
    static func from(transcript: String, date: Date = .now, calendar: Calendar = .current, language: String? = nil) -> String {
        let words = DisfluencyFilter.cleaned(transcript, language: language)
            .split(whereSeparator: \Character.isWhitespace)
            .prefix(7)

        guard !words.isEmpty else {
            return date.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened, locale: calendar.locale ?? .current)
            )
        }

        let title = words.joined(separator: " ")
        return title.count > 52 ? String(title.prefix(49)) + "…" : title
    }
}
