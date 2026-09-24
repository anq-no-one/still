import Foundation

struct VocabularyTerm: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    private(set) var stampedTerm: Stamped<String>
    private(set) var stampedVariants: Stamped<[String]>
    private(set) var stampedDeleted: Stamped<Bool>

    init(id: UUID = UUID(), term: String, variants: [String] = [], at date: Date = .now) {
        self.id = id
        stampedTerm = Stamped(value: term, stampedAt: date)
        stampedVariants = Stamped(value: Self.normalized(variants, excluding: term), stampedAt: date)
        stampedDeleted = Stamped(value: false, stampedAt: date)
    }

    var term: String {
        stampedTerm.value
    }

    var variants: [String] {
        stampedVariants.value
    }

    var isDeleted: Bool {
        stampedDeleted.value
    }

    var updatedAt: Date {
        max(stampedTerm.stampedAt, stampedVariants.stampedAt, stampedDeleted.stampedAt)
    }

    mutating func rename(to term: String, at date: Date = .now) {
        stampedTerm = Stamped(value: term, stampedAt: date)
        stampedVariants = Stamped(value: Self.normalized(variants, excluding: term), stampedAt: date)
    }

    mutating func setVariants(_ variants: [String], at date: Date = .now) {
        stampedVariants = Stamped(value: Self.normalized(variants, excluding: term), stampedAt: date)
    }

    mutating func markDeleted(at date: Date = .now) {
        stampedDeleted = Stamped(value: true, stampedAt: date)
    }

    /// Each field follows its own latest edit, matching Project.merge, so a
    /// rename on one device and a variant edit on another both survive.
    static func merge(_ first: VocabularyTerm, _ second: VocabularyTerm) -> VocabularyTerm {
        guard first.id == second.id else { return first }

        var merged = first
        merged.stampedTerm = .latest(first.stampedTerm, second.stampedTerm)
        merged.stampedVariants = .latest(first.stampedVariants, second.stampedVariants)
        merged.stampedDeleted = .latest(first.stampedDeleted, second.stampedDeleted)
        return merged
    }

    /// Trims whitespace, drops the term's own spelling (case-insensitively,
    /// matching the corrector's case-only self normalization), and
    /// de-duplicates case- and diacritic-insensitively while keeping each
    /// variant's first spelling, so "Kubernetes" stays out of its own
    /// variant list and "Kuber Nettis" doesn't sit beside "kuber nettis".
    static func normalized(_ variants: [String], excluding term: String) -> [String] {
        let termKey = term.folding(options: .caseInsensitive, locale: nil)
        var seen = Set<String>()
        var result: [String] = []
        for variant in variants {
            let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.folding(options: .caseInsensitive, locale: nil) != termKey else { continue }
            guard seen.insert(dedupeKey(trimmed)).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func dedupeKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

struct ProjectVocabulary: Codable, Equatable, Sendable {
    let projectID: UUID
    private(set) var terms: [VocabularyTerm]

    init(projectID: UUID, terms: [VocabularyTerm] = []) {
        self.projectID = projectID
        self.terms = terms
    }

    var activeTerms: [VocabularyTerm] {
        terms.filter { !$0.isDeleted }
    }

    mutating func upsert(_ term: VocabularyTerm) {
        if let index = terms.firstIndex(where: { $0.id == term.id }) {
            terms[index] = term
        } else {
            terms.append(term)
        }
    }

    mutating func delete(_ id: UUID, at date: Date = .now) {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        terms[index].markDeleted(at: date)
    }

    /// Terms held by only one side are unioned in; terms held by both merge
    /// field by field, so a tombstone from one device outlives a stale edit
    /// from another.
    static func merge(_ first: ProjectVocabulary, _ second: ProjectVocabulary) -> ProjectVocabulary {
        guard first.projectID == second.projectID else { return first }

        var byID: [UUID: VocabularyTerm] = [:]
        for term in first.terms {
            byID[term.id] = term
        }
        for term in second.terms {
            byID[term.id] = byID[term.id].map { VocabularyTerm.merge($0, term) } ?? term
        }
        return ProjectVocabulary(projectID: first.projectID, terms: Array(byID.values))
    }
}
