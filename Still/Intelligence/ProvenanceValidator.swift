import Foundation

struct ProvenanceValidator: Sendable {
    struct Outcome: Equatable, Sendable {
        let items: [MemoryItem]
        let withheld: Int
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "are", "was", "were", "will", "would", "should", "could",
        "have", "has", "had", "been", "being", "from", "into", "onto", "about", "they", "them", "their", "there",
        "then", "than", "what", "when", "which", "who", "whom", "our", "ours", "you", "your", "yours", "she", "her",
        "his", "him", "its", "all", "any", "but", "not", "can", "did", "does", "doing", "done", "let", "lets",
        "also", "just", "very", "some", "such", "these", "those",
    ]

    let minimumSupport: Double

    init(minimumSupport: Double = 0.6) {
        self.minimumSupport = minimumSupport
    }

    func validate(_ candidates: [ExtractionCandidate], against segments: [TranscriptSegment], speakers: [Speaker] = []) -> Outcome {
        let order = Dictionary(segments.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [MemoryItem] = []
        var withheld = 0

        for candidate in candidates {
            let cited = Array(Set(candidate.citedSegmentIDs))
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !cited.isEmpty, cited.allSatisfy({ order[$0] != nil }) else {
                withheld += 1
                continue
            }

            let sources = cited.compactMap { order[$0] }.sorted().map { segments[$0] }
            let evidence = sources.map(\.displayText).joined(separator: " ")
            guard support(of: text, in: evidence) >= minimumSupport else {
                withheld += 1
                continue
            }

            kept.append(
                MemoryItem(
                    kind: candidate.kind,
                    text: text,
                    sourceSegmentIDs: sources.map(\.id),
                    sourceStart: sources.map(\.start).min() ?? 0,
                    owner: supportedOwner(candidate.owner, evidence: evidence, speakers: speakers),
                    due: supportedDetail(candidate.due, evidence: evidence)
                )
            )
        }

        return Outcome(items: kept, withheld: withheld)
    }

    func support(of text: String, in evidence: String) -> Double {
        let terms = Set(Self.keyTerms(in: text))
        guard !terms.isEmpty else { return 0 }

        let heard = Set(MemoryText.words(in: evidence))
        let supported = terms.filter { term in heard.contains { Self.matches(term, $0) } }
        return Double(supported.count) / Double(terms.count)
    }

    static func keyTerms(in text: String) -> [String] {
        MemoryText.words(in: text).filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private static func matches(_ term: String, _ word: String) -> Bool {
        guard term != word else { return true }
        guard term.count >= 4, word.count >= 4 else { return false }

        return term.hasPrefix(word) || word.hasPrefix(term) || term.prefix(5) == word.prefix(5)
    }

    private func supportedOwner(_ owner: String?, evidence: String, speakers: [Speaker]) -> String? {
        guard let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else { return nil }

        let named = speakers.contains { MemoryText.normalized($0.name) == MemoryText.normalized(owner) }
        return named ? owner : supportedDetail(owner, evidence: evidence)
    }

    private func supportedDetail(_ detail: String?, evidence: String) -> String? {
        guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else { return nil }

        let words = MemoryText.words(in: detail)
        let heard = Set(MemoryText.words(in: evidence))
        return !words.isEmpty && words.allSatisfy(heard.contains) ? detail : nil
    }
}
