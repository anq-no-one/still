import Foundation

enum TitleSource: String, Codable, Sendable {
    case automatic
    case user
}

struct TitleRequest: Sendable {
    let segments: [TranscriptSegment]
    let calendarTitle: String?
    let language: String?

    func excerpt(characterBudget: Int) -> String {
        let sentences = ExtractiveNoteGenerator.sentences(in: segments)
            .map { TitleText.tidy($0.text) }
            .filter { !TitleText.isSmallTalk($0) }
        guard !sentences.isEmpty else { return "" }

        let total = sentences.reduce(0) { $0 + $1.count + 1 }
        if total <= characterBudget {
            return sentences.joined(separator: " ")
        }

        let average = max(1, total / sentences.count)
        let count = max(2, min(sentences.count, characterBudget / average))
        let picks = (0..<count).map { $0 * (sentences.count - 1) / (count - 1) }
        var chosen: [String] = []
        var used = 0
        for index in Set(picks).sorted() {
            let sentence = sentences[index]
            guard used + sentence.count + 1 <= characterBudget else { continue }
            chosen.append(sentence)
            used += sentence.count + 1
        }
        return chosen.joined(separator: " ")
    }
}

enum TitleText {
    static let maximumLength = 52
    static let maximumWords = 7

    private static let greetings: Set<String> = [
        "hi", "hey", "hello", "hallo", "hola", "salut", "ciao", "bonjour", "cześć", "czesc",
        "привет", "привіт", "здравствуйте", "добрый", "добрий", "morning", "afternoon", "evening",
    ]

    private static let smallTalk: Set<String> = [
        "hi", "hey", "hello", "good", "morning", "afternoon", "evening", "everyone", "everybody", "guys",
        "how", "are", "you", "doing", "is", "it", "going", "fine", "great", "thanks", "thank", "okay", "ok",
        "yeah", "yes", "yep", "no", "nope", "sure", "right", "so", "well", "can", "hear", "me", "see", "my",
        "screen", "i", "am", "i'm", "we", "all", "bye", "goodbye", "later", "nice", "to", "meet", "too",
        "alright", "cool", "oh", "and", "the", "a", "there", "here", "again", "awesome", "perfect", "sounds",
        "you're", "your", "do", "what's", "up", "not", "bad", "much", "very", "just", "let", "me", "share",
    ]

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from",
        "is", "are", "was", "were", "be", "been", "it", "this", "that", "these", "those", "we", "you", "i",
        "they", "he", "she", "our", "your", "my", "their", "so", "then", "there", "here", "about", "should",
        "would", "could", "will", "can", "just", "also", "very", "really", "have", "has", "had", "do", "does",
        "did", "not", "let's", "lets", "need", "needs", "some", "any", "all", "what", "which", "when", "how",
    ]

    private static let trailingJoiners: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "by", "from", "about",
    ]

    static func cleaned(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline) else { return nil }
        let unquoted = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»`"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!").union(.whitespaces))
        guard !unquoted.isEmpty, unquoted.count <= maximumLength, !isSmallTalk(unquoted) else { return nil }
        return unquoted
    }

    static func isSmallTalk(_ sentence: String) -> Bool {
        let words = normalizedWords(sentence)
        guard let first = words.first else { return true }
        if greetings.contains(first), words.count <= 8 { return true }
        return words.allSatisfy(smallTalk.contains)
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    static func contentWords(_ text: String) -> [String] {
        normalizedWords(text).filter { !stopWords.contains($0) && !smallTalk.contains($0) && $0.count > 2 }
    }

    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+([.,?!;:])"#, with: "$1", options: .regularExpression)
    }

    static func shortened(_ sentence: String) -> String {
        var words = tidy(sentence)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!").union(.whitespaces))
            .split(whereSeparator: \.isWhitespace)
            .prefix(maximumWords)
            .map(String.init)
        while words.count > 1, let last = words.last,
              trailingJoiners.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            words.removeLast()
        }
        let title = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        return title.count > maximumLength ? String(title.prefix(maximumLength - 3)) + "…" : title
    }
}

enum RecordingTitle {
    static func from(transcript: String, date: Date = .now, calendar: Calendar = .current, language: String? = nil) -> String {
        let cleaned = DisfluencyFilter.cleaned(transcript, language: language)
        guard let sentence = keySentence(in: cleaned) else {
            return dateTitle(date, calendar: calendar)
        }
        return TitleText.shortened(sentence)
    }

    static func dateTitle(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: calendar.locale ?? .current))
    }

    private static func keySentence(in text: String) -> String? {
        let sentences = text
            .split(omittingEmptySubsequences: true, whereSeparator: { ".?!".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty && !TitleText.isSmallTalk($0) }
        guard !sentences.isEmpty else { return nil }

        let frequency = sentences
            .flatMap { Set(TitleText.contentWords($0)) }
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var best = sentences[0]
        var bestScore = -1
        for sentence in sentences {
            let score = Set(TitleText.contentWords(sentence)).reduce(0) { $0 + (frequency[$1, default: 1] - 1) }
            if score > bestScore {
                best = sentence
                bestScore = score
            }
        }
        return best
    }
}
