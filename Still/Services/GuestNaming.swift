import Foundation
import NaturalLanguage

enum GuestNaming {
    static func name(
        _ transcription: TranscriptionResult,
        cues: [SpeakerCue] = [],
        roster: [String] = [],
        ownerName: String? = nil
    ) -> TranscriptionResult {
        let cued = SpeakerCueMatcher.suggest(cues, for: transcription, ownerName: ownerName)
        let votes = SpokenNames.votes(in: cued)
        return resolve(cued, votes: votes, roster: roster, ownerName: ownerName)
    }

    private struct Candidate {
        let speakerID: UUID
        let name: String
        let source: Speaker.NameSource
        let applies: Bool
        let score: Int
    }

    private static func resolve(
        _ transcription: TranscriptionResult,
        votes: [SpokenNames.Vote],
        roster: [String],
        ownerName: String?
    ) -> TranscriptionResult {
        var taken = Set(transcription.speakers.filter { !$0.isUnnamedGuest }.map { VoiceProfiles.key(for: $0.name) })
        let ownerKeys = ownerName.map { [VoiceProfiles.key(for: $0), firstNameKey($0)] } ?? []
        func isOwner(_ name: String) -> Bool {
            ownerKeys.contains(VoiceProfiles.key(for: name)) || ownerKeys.contains(firstNameKey(name))
        }

        let byListener = Dictionary(grouping: votes, by: \.speakerID)
        var candidates: [Candidate] = []
        for speaker in transcription.speakers where speaker.isUnnamedGuest {
            let cueName = speaker.suggestedName
            let spoken = byListener[speaker.id].flatMap { winner(of: $0, roster: roster) }
            if let cueName, let spoken, sameName(cueName, spoken.name) {
                candidates.append(Candidate(speakerID: speaker.id, name: cueName, source: .callCue, applies: true, score: spoken.count + 10))
            } else if let spoken, cueName == nil {
                candidates.append(Candidate(
                    speakerID: speaker.id,
                    name: spoken.name,
                    source: .spoken,
                    applies: spoken.count >= 2 && spoken.isUnanimous,
                    score: spoken.count
                ))
            } else if let cueName {
                candidates.append(Candidate(speakerID: speaker.id, name: cueName, source: .callCue, applies: false, score: 5))
            }
        }

        var decided: [UUID: Candidate] = [:]
        for candidate in candidates.sorted(by: { ($0.applies ? 1 : 0, $0.score) > ($1.applies ? 1 : 0, $1.score) }) {
            let key = VoiceProfiles.key(for: candidate.name)
            guard !taken.contains(key), !isOwner(candidate.name) else { continue }
            taken.insert(key)
            decided[candidate.speakerID] = candidate
        }

        var result = transcription
        result.speakers = transcription.speakers.map { speaker in
            guard speaker.isUnnamedGuest else { return speaker }
            guard let candidate = decided[speaker.id] else { return speaker.rejectingSuggestedName() }
            return candidate.applies
                ? speaker.named(candidate.name, by: candidate.source)
                : speaker.suggesting(candidate.name)
        }
        return result
    }

    private struct Winner {
        let name: String
        let count: Int
        let isUnanimous: Bool
    }

    private static func winner(of votes: [SpokenNames.Vote], roster: [String]) -> Winner? {
        let resolved = votes.compactMap { vote in resolve(vote.name, against: roster) }
        guard !resolved.isEmpty else { return nil }
        let counts = Dictionary(grouping: resolved, by: { VoiceProfiles.key(for: $0) })
        guard let top = counts.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) else { return nil }
        let others = resolved.count - top.value.count
        guard top.value.count > others else { return nil }
        return Winner(name: top.value[0], count: top.value.count, isUnanimous: others == 0)
    }

    private static func resolve(_ spoken: String, against roster: [String]) -> String? {
        let present = roster.filter { !VoiceProfiles.key(for: $0).isEmpty }
        guard present.count >= 2 else { return present.first.map { sameName($0, spoken) ? $0 : spoken } ?? spoken }
        if let exact = present.first(where: { VoiceProfiles.key(for: $0) == VoiceProfiles.key(for: spoken) }) {
            return exact
        }
        let byFirstName = present.filter { firstNameKey($0) == firstNameKey(spoken) }
        return byFirstName.count == 1 ? byFirstName[0] : nil
    }

    static func sameName(_ full: String, _ spoken: String) -> Bool {
        VoiceProfiles.key(for: full) == VoiceProfiles.key(for: spoken) || firstNameKey(full) == VoiceProfiles.key(for: spoken)
            || firstNameKey(spoken) == VoiceProfiles.key(for: full)
    }

    static func firstNameKey(_ name: String) -> String {
        VoiceProfiles.key(for: name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name)
    }
}

enum SpokenNames {
    struct Vote: Equatable, Sendable {
        let speakerID: UUID
        let name: String
    }

    private struct Turn {
        let speakerID: UUID
        var text: String
        let start: TimeInterval
        var end: TimeInterval
    }

    private enum Listener {
        case previous
        case next
        case same
    }

    static let maximumGap: TimeInterval = 20

    private static let greetings: Set<String> = [
        "hey", "hi", "hello", "morning", "good", "afternoon", "evening", "welcome", "bye", "goodbye",
        "привет", "привіт", "здравствуйте", "hallo", "hola", "salut", "bonjour", "ciao", "cześć", "czesc",
    ]

    private static let thanks: Set<String> = [
        "thanks", "thank", "cheers", "спасибо", "дякую", "danke", "gracias", "merci", "grazie", "dzięki", "dziekuje",
    ]

    private static let discourse: Set<String> = [
        "so", "ok", "okay", "and", "yes", "yeah", "right", "well", "great", "cool", "now", "alright", "sure", "oh", "then",
    ]

    private static let introductions = ["my name is", "this is", "i'm", "i am", "it's", "меня зовут", "мене звати", "ich bin", "je suis", "soy", "sono", "jestem"]

    private static let notNames: Set<String> = [
        "siri", "alexa", "google", "zoom", "teams", "meet", "slack", "figma", "jira", "notion", "god", "guys", "everyone",
        "everybody", "team", "folks", "all", "sorry", "yesterday", "today", "tomorrow", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december", "i", "ok", "okay", "hey", "hi", "hello", "thanks",
    ]

    static func votes(in transcription: TranscriptionResult) -> [Vote] {
        let you = Set(transcription.speakers.filter(\.isYou).map(\.id))
        let turns = self.turns(of: transcription.segments)
        var votes: [Vote] = []
        for (index, turn) in turns.enumerated() {
            for (name, listener) in addressedNames(in: turn.text) {
                let target: Turn?
                switch listener {
                case .same:
                    target = turn
                case .previous:
                    target = index > 0 && turn.start - turns[index - 1].end <= maximumGap ? turns[index - 1] : nil
                case .next:
                    target = index + 1 < turns.count && turns[index + 1].start - turn.end <= maximumGap ? turns[index + 1] : nil
                }
                guard let target, !you.contains(target.speakerID) else { continue }
                if listener != .same, target.speakerID == turn.speakerID { continue }
                votes.append(Vote(speakerID: target.speakerID, name: name))
            }
        }
        return votes
    }

    private static func turns(of segments: [TranscriptSegment]) -> [Turn] {
        segments.sorted { $0.start < $1.start }.reduce(into: []) { turns, segment in
            guard let speakerID = segment.speakerID else { return }
            let text = segment.displayText
            if let last = turns.last, last.speakerID == speakerID {
                turns[turns.count - 1].text += " " + text
                turns[turns.count - 1].end = max(last.end, segment.end)
            } else {
                turns.append(Turn(speakerID: speakerID, text: text, start: segment.start, end: segment.end))
            }
        }
    }

    private static func addressedNames(in text: String) -> [(String, Listener)] {
        let tagged = personalNames(in: text)
        var found: [(String, Listener)] = []
        for sentence in sentences(of: text) {
            for range in nameRanges(in: sentence, tagged: tagged) {
                let name = String(sentence[range])
                guard isPlausibleName(name) else { continue }
                if let listener = listener(for: range, in: sentence) {
                    found.append((name, listener))
                }
            }
        }
        return found
    }

    private static func listener(for range: Range<String.Index>, in sentence: String) -> Listener? {
        let before = sentence[..<range.lowerBound]
        let after = sentence[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let beforeLower = before.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        let beforeWords = TitleText.normalizedWords(String(before))

        if introductions.contains(where: { beforeLower.hasSuffix($0) }) || (beforeWords.isEmpty && after.lowercased().hasPrefix("here")) {
            return .same
        }

        let followedByBreak = after.isEmpty || after.first.map { ",.?!;:".contains($0) } == true
        let thanked = beforeWords.contains(where: thanks.contains)
        if !beforeWords.isEmpty, beforeWords.allSatisfy({ greetings.contains($0) || thanks.contains($0) || discourse.contains($0) || $0 == "you" }) {
            guard followedByBreak || beforeWords.contains(where: greetings.contains) else { return nil }
            return thanked ? .previous : .next
        }
        if beforeWords.isEmpty {
            return followedByBreak && after.hasPrefix(",") ? .next : nil
        }

        let endsSentence = after.allSatisfy { ".?!".contains($0) }
        guard before.trimmingCharacters(in: .whitespaces).hasSuffix(","), endsSentence else { return nil }
        if thanked { return .previous }
        if after.contains("?") || after.contains("!") || beforeWords.contains(where: greetings.contains) { return .next }
        return nil
    }

    private static func sentences(of text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".?!".contains(character) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    private static func personalNames(in text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: Set<String> = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            if tag == .personalName {
                let words = text[range].split(separator: " ").drop { greetings.contains($0.lowercased()) }
                if !words.isEmpty { names.insert(words.joined(separator: " ")) }
            }
            return true
        }
        return names
    }

    private static func nameRanges(in sentence: String, tagged: Set<String>) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for name in tagged.sorted(by: { $0.count > $1.count }) {
            var searchStart = sentence.startIndex
            while let range = sentence.range(of: name, range: searchStart..<sentence.endIndex) {
                if !ranges.contains(where: { $0.overlaps(range) }), isWholeWord(range, in: sentence) {
                    ranges.append(range)
                }
                searchStart = range.upperBound
            }
        }
        if let greeted = nameAfterGreeting(in: sentence), !ranges.contains(where: { $0.overlaps(greeted) }) {
            ranges.append(greeted)
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func nameAfterGreeting(in sentence: String) -> Range<String.Index>? {
        let pattern = #"^(?i:(?:hey|hi|hello|thanks|thank you|привет|привіт|спасибо|дякую|hallo|danke|hola|gracias|salut|merci|ciao|grazie|cześć|dzięki))[,!]?\s+(\p{Lu}[\p{Ll}'’-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)),
              let range = Range(match.range(at: 1), in: sentence)
        else { return nil }
        return range
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        let beforeOK = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
        let afterOK = range.upperBound == text.endIndex || !text[range.upperBound].isLetter
        return beforeOK && afterOK
    }

    private static func isPlausibleName(_ name: String) -> Bool {
        let words = name.split(separator: " ")
        guard !words.isEmpty, words.count <= 3 else { return false }
        return words.allSatisfy { word in
            guard let first = word.first, first.isUppercase, word.count >= 2 else { return false }
            return !notNames.contains(word.lowercased())
        }
    }
}
