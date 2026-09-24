import Foundation

struct DecisionThread: Identifiable, Equatable, Sendable {
    let current: SourcedItem
    let earlier: [SourcedItem]
    let hasChanged: Bool

    var id: String {
        current.id
    }
}

struct ProjectHistory: Equatable, Sendable {
    let threads: [DecisionThread]

    init(recordings: [Recording], project projectID: UUID, validator: ProvenanceValidator = ProvenanceValidator()) {
        let decisions = recordings
            .filter { $0.projectID == projectID && $0.isProjectConfirmed && !$0.isDeleted }
            .flatMap { recording in
                (recording.memory?.items(of: .decision) ?? [])
                    .filter { !$0.isDeclined && validator.stillSupports($0, in: recording.segments) }
                    .map { SourcedItem($0, in: recording) }
            }
            .sorted(by: Self.isEarlier)

        var groups: [[SubjectDecision]] = []
        for decision in decisions.map(SubjectDecision.init) {
            let candidates = groups.indices.filter { index in
                groups[index].contains { decision.subject.isSameSubject(as: $0.subject) }
            }
            let match = candidates.max { first, second in
                decision.closeness(to: groups[first]) < decision.closeness(to: groups[second])
            }
            if let match {
                groups[match].append(decision)
            } else {
                groups.append([decision])
            }
        }

        threads = groups
            .compactMap { group in
                guard let current = group.last else { return nil }

                let earlier = group.dropLast()
                return DecisionThread(
                    current: current.item,
                    earlier: earlier.reversed().map(\.item),
                    hasChanged: earlier.contains { !$0.subject.restates(current.subject) }
                )
            }
            .sorted { Self.isEarlier($1.current, $0.current) }
    }

    var current: [SourcedItem] {
        threads.map(\.current)
    }

    var superseded: [SourcedItem] {
        threads.flatMap(\.earlier)
    }

    static func isEarlier(_ first: SourcedItem, _ second: SourcedItem) -> Bool {
        if first.recordingDate != second.recordingDate { return first.recordingDate < second.recordingDate }
        if first.time != second.time { return first.time < second.time }

        let firstConfirmed = first.item.status == .confirmed
        let secondConfirmed = second.item.status == .confirmed
        if firstConfirmed != secondConfirmed { return secondConfirmed }
        return first.id < second.id
    }
}

private struct SubjectDecision {
    let item: SourcedItem
    let subject: DecisionSubject

    init(_ item: SourcedItem) {
        self.item = item
        subject = DecisionSubject(item.item.text)
    }

    func closeness(to group: [SubjectDecision]) -> Double {
        group.last.map { subject.overlap(with: $0.subject) } ?? 0
    }
}

struct DecisionSubject: Equatable, Sendable {
    static let cueWords: Set<String> = [
        "decided", "decide", "decision", "decisions", "agreed", "agree", "agreement", "settled", "going",
        "instead", "actually", "now", "okay", "final", "finally",
    ]

    let terms: [String]

    init(_ text: String) {
        terms = Set(ProvenanceValidator.keyTerms(in: text).filter { !Self.cueWords.contains($0) }).sorted()
    }

    func isSameSubject(as other: DecisionSubject) -> Bool {
        let smaller = min(terms.count, other.terms.count)
        guard smaller > 0 else { return false }

        return sharedCount(with: other) >= min(2, smaller) && overlap(with: other) >= 0.5
    }

    func restates(_ other: DecisionSubject) -> Bool {
        sharedCount(with: other) == max(terms.count, other.terms.count)
    }

    func overlap(with other: DecisionSubject) -> Double {
        let smaller = min(terms.count, other.terms.count)
        return smaller == 0 ? 0 : Double(sharedCount(with: other)) / Double(smaller)
    }

    private func sharedCount(with other: DecisionSubject) -> Int {
        let (few, many) = terms.count <= other.terms.count ? (terms, other.terms) : (other.terms, terms)
        return few.filter { term in many.contains { ProvenanceValidator.matches(term, $0) } }.count
    }
}
