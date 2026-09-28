import Foundation

enum DisfluencyFilter {
    static let fillers: [String: Set<String>] = [
        "en": ["um", "umm", "uh", "uhh", "uhm", "er", "ah", "hmm", "hm", "mm", "mhm"],
        "de": ["äh", "ähm", "hm", "hmm", "ähmm"],
        "fr": ["euh", "heu", "hum", "hm", "hmm"],
        "es": ["eh", "eeh", "este", "mmm", "em"],
        "it": ["eh", "ehm", "beh", "mmm", "hm"],
        "pt": ["éh", "hum", "hã", "ãh", "hm"],
        "nl": ["eh", "ehm", "uh", "hm", "hmm"],
        "pl": ["yyy", "eee", "ych", "mm", "hm"],
        "ru": ["э", "ээ", "эм", "м", "мм", "гм", "хм"],
        "uk": ["е", "ее", "ем", "м", "мм", "гм", "хм"],
        "da": ["øh", "ah", "hm", "hmm"],
        "sv": ["öh", "ah", "hm", "hmm"],
        "cs": ["ehm", "hm", "mmm", "é"],
        "sk": ["ehm", "hm", "mmm"],
        "bg": ["ъ", "ъм", "а", "хм"],
        "hr": ["ovaj", "hm", "mmm"],
        "sl": ["ehm", "hm", "mmm"],
        "ro": ["ă", "î", "hm", "mmm"],
        "hu": ["öö", "eh", "hm", "mmm"],
        "fi": ["öö", "tuota", "hm", "mmm"],
        "et": ["ee", "hm", "mmm"],
        "lv": ["hm", "mmm", "ē"],
        "lt": ["hm", "mmm", "ė"],
        "el": ["ε", "εμ", "χμ"],
        "mt": ["em", "e", "hm"],
    ]

    static func cleaned(_ text: String, language: String?) -> String {
        let fillers = fillers(for: language)
        var kept: [String] = []
        for token in text.split(separator: " ").map(String.init) {
            let key = comparisonKey(of: token)
            guard key.containsLetterOrNumber else {
                kept.append(token)
                continue
            }
            if fillers.contains(key) { continue }
            if let last = kept.last, comparisonKey(of: last) == key { continue }
            kept.append(token)
        }
        return kept.joined(separator: " ")
    }

    static func isFillerOnly(_ text: String, language: String?) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cleaned(text, language: language).isEmpty
    }

    static func cleanedDisplayText(of segment: TranscriptSegment) -> String {
        cleaned(segment.displayText, language: segment.language)
    }

    static func fillers(for language: String?) -> Set<String> {
        guard let language else { return fillers["en"] ?? [] }
        let code = String(language.lowercased().prefix(2))
        return fillers[code] ?? fillers["en"] ?? []
    }

    private static func comparisonKey(of token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }
}

private extension String {
    var containsLetterOrNumber: Bool {
        contains { $0.isLetter || $0.isNumber }
    }
}
