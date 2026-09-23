import Foundation
import NaturalLanguage

enum TranscriptPhrases {
    static let pauseSeconds: TimeInterval = 1.2

    static func segments(from words: [SpokenWord]) -> [TranscriptSegment] {
        var phrases: [[SpokenWord]] = []
        var current: [SpokenWord] = []

        for word in words {
            if let last = current.last, word.start - last.end >= pauseSeconds {
                phrases.append(current)
                current = []
            }
            current.append(word)
            if let mark = word.text.last, ".?!".contains(mark) {
                phrases.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            phrases.append(current)
        }

        return phrases.compactMap { phrase in
            guard let first = phrase.first, let last = phrase.last else { return nil }

            let text = phrase.map(\.text).joined(separator: " ")
            return TranscriptSegment(
                start: first.start,
                end: last.end,
                text: text,
                language: language(of: text),
                confidence: phrase.map(\.confidence).reduce(0, +) / Double(phrase.count)
            )
        }
    }

    static func plainText(of words: [SpokenWord]) -> String {
        words.map(\.text).joined(separator: " ")
    }

    private static func language(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }
}
