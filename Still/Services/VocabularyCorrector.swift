import Foundation

/// Applies a project's vocabulary to a fresh transcript, whole word by whole
/// word. It never touches text inside a larger word, and it folds case and
/// diacritics before comparing so "cooper netties" or "КУБЕРНЕТЕС" both find
/// their term. It only ever runs on a new recording's own segments, so an
/// earlier recording is never rewritten when a term is added later.
struct VocabularyChange: Identifiable, Equatable, Sendable {
    let segmentID: UUID
    let before: String
    let after: String

    var id: UUID { segmentID }
}

enum VocabularyCorrector {
    static func changes(_ vocabulary: ProjectVocabulary, for segments: [TranscriptSegment]) -> [VocabularyChange] {
        let untouched = segments.filter { !$0.isCorrected }
        return apply(vocabulary, to: untouched).compactMap { segment in
            segment.correction.map { VocabularyChange(segmentID: segment.id, before: segment.text, after: $0) }
        }
    }

    static func apply(_ vocabulary: ProjectVocabulary, to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let entries = matchEntries(for: vocabulary.activeTerms)
        guard !entries.isEmpty else { return segments }

        let corrected = segments.map { segment -> TranscriptSegment in
            guard let corrected = correct(segment.text, using: entries), corrected != segment.text else {
                return segment
            }
            var copy = segment
            copy.correction = corrected
            return copy
        }
        return joinAcrossBoundaries(corrected, using: entries)
    }

    private static func joinAcrossBoundaries(_ segments: [TranscriptSegment], using entries: [Entry]) -> [TranscriptSegment] {
        guard segments.count >= 2 else { return segments }
        var result = segments
        for index in result.indices.dropLast() {
            guard result[index].correction == nil, result[index + 1].correction == nil else { continue }
            guard let match = boundaryMatch(ending: result[index], starting: result[index + 1], entries: entries) else {
                continue
            }
            var first = result[index]
            var second = result[index + 1]
            first.correction = String(first.displayText[..<match.firstCut]) + match.entry.replacement
            second.correction = String(second.displayText[match.secondCut...].trimmingCharacters(in: .whitespaces))
            result[index] = first
            result[index + 1] = second
        }
        return result
    }

    private static func boundaryMatch(
        ending first: TranscriptSegment,
        starting second: TranscriptSegment,
        entries: [Entry]
    ) -> (entry: Entry, firstCut: String.Index, secondCut: String.Index)? {
        let firstTokens = wordTokens(in: first.displayText)
        let secondTokens = wordTokens(in: second.displayText)
        guard !firstTokens.isEmpty, !secondTokens.isEmpty else { return nil }
        for entry in entries where entry.words.count >= 2 {
            for taken in 1..<entry.words.count {
                guard taken <= firstTokens.count, entry.words.count - taken <= secondTokens.count else { continue }
                let tail = firstTokens.suffix(taken).map { fold($0.word, diacriticInsensitive: entry.diacriticInsensitive) }
                let head = secondTokens.prefix(entry.words.count - taken).map {
                    fold($0.word, diacriticInsensitive: entry.diacriticInsensitive)
                }
                if Array(tail) + Array(head) == entry.words {
                    return (entry, firstTokens[firstTokens.count - taken].range.lowerBound, secondTokens[entry.words.count - taken - 1].range.upperBound)
                }
            }
        }
        return nil
    }

    private struct Entry {
        let words: [String]
        let replacement: String
        let diacriticInsensitive: Bool
    }

    private struct Token {
        let word: String
        let range: Range<String.Index>
    }

    /// The term's own spelling only normalizes case, so a transcript that
    /// already spells it with different diacritics is left alone unless the
    /// user lists that spelling as a variant. Variants fold case and
    /// diacritics, since they stand for whatever the recognizer misheard.
    /// Longest word count first, so a two-word variant like "cooper netties"
    /// wins over a one-word variant that happens to match part of it.
    private static func matchEntries(for terms: [VocabularyTerm]) -> [Entry] {
        var entries: [Entry] = []
        for term in terms {
            let ownWords = foldedWords(of: term.term, diacriticInsensitive: false)
            if !ownWords.isEmpty {
                entries.append(Entry(words: ownWords, replacement: term.term, diacriticInsensitive: false))
            }
            for variant in Set(term.variants) {
                let words = foldedWords(of: variant, diacriticInsensitive: true)
                guard !words.isEmpty else { continue }
                entries.append(Entry(words: words, replacement: term.term, diacriticInsensitive: true))
            }
        }
        return entries.sorted { lhs, rhs in
            lhs.words.count != rhs.words.count
                ? lhs.words.count > rhs.words.count
                : lhs.words.joined().count > rhs.words.joined().count
        }
    }

    private static func correct(_ text: String, using entries: [Entry]) -> String? {
        let tokens = wordTokens(in: text)
        guard !tokens.isEmpty else { return nil }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        var index = 0
        while index < tokens.count {
            guard let match = firstMatch(at: index, in: tokens, entries: entries) else {
                index += 1
                continue
            }

            let start = tokens[index].range.lowerBound
            let end = tokens[match.end - 1].range.upperBound
            if text[start..<end] != match.entry.replacement {
                replacements.append((start..<end, match.entry.replacement))
            }
            index = match.end
        }

        guard !replacements.isEmpty else { return nil }

        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func firstMatch(at index: Int, in tokens: [Token], entries: [Entry]) -> (entry: Entry, end: Int)? {
        for entry in entries {
            let span = entry.words.count
            guard index + span <= tokens.count else { continue }
            let candidate = tokens[index..<(index + span)].map { fold($0.word, diacriticInsensitive: entry.diacriticInsensitive) }
            if candidate == entry.words {
                return (entry, index + span)
            }
        }
        return nil
    }

    private static func wordTokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { substring, range, _, _ in
            guard let substring else { return }
            tokens.append(Token(word: substring, range: range))
        }
        return tokens
    }

    private static func foldedWords(of text: String, diacriticInsensitive: Bool) -> [String] {
        wordTokens(in: text).map { fold($0.word, diacriticInsensitive: diacriticInsensitive) }
    }

    private static func fold(_ text: String, diacriticInsensitive: Bool) -> String {
        text.folding(
            options: diacriticInsensitive ? [.caseInsensitive, .diacriticInsensitive] : [.caseInsensitive],
            locale: nil
        )
    }
}
