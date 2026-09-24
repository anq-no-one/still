import CryptoKit
import Foundation

enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case decision
    case fact
    case task
}

enum MemoryReview: String, Codable, Sendable {
    case approved
    case declined
}

enum MemoryStatus: Equatable, Sendable {
    case extracted
    case confirmed
    case rejected
    case proposed
    case accepted
    case dismissed
}

struct MemoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: MemoryKind
    let extractedText: String
    let sourceSegmentIDs: [UUID]
    let sourceStart: TimeInterval
    let owner: String?
    let due: String?
    private(set) var review: Stamped<MemoryReview>?
    private(set) var edit: Stamped<String>?

    init(
        kind: MemoryKind,
        text: String,
        sourceSegmentIDs: [UUID],
        sourceStart: TimeInterval,
        owner: String? = nil,
        due: String? = nil
    ) {
        id = Self.identity(kind: kind, sourceSegmentIDs: sourceSegmentIDs, text: text)
        self.kind = kind
        extractedText = text
        self.sourceSegmentIDs = sourceSegmentIDs
        self.sourceStart = sourceStart
        self.owner = owner
        self.due = due
    }

    var text: String {
        edit?.value ?? extractedText
    }

    var isEdited: Bool {
        edit != nil
    }

    var isUserTouched: Bool {
        review != nil || edit != nil
    }

    var isAutomaticallyExtracted: Bool {
        review == nil
    }

    var status: MemoryStatus {
        switch (kind, review?.value) {
        case (.task, nil): .proposed
        case (.task, .approved): .accepted
        case (.task, .declined): .dismissed
        case (_, nil): .extracted
        case (_, .approved): .confirmed
        case (_, .declined): .rejected
        }
    }

    var isDeclined: Bool {
        review?.value == .declined
    }

    func reviewed(_ review: MemoryReview, at date: Date = .now) -> MemoryItem {
        var reviewed = self
        reviewed.review = Stamped(value: review, stampedAt: date)
        return reviewed
    }

    func edited(to text: String, at date: Date = .now) -> MemoryItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != self.text else { return self }

        var edited = self
        edited.edit = Stamped(value: trimmed, stampedAt: date)
        return edited
    }

    static func identity(kind: MemoryKind, sourceSegmentIDs: [UUID], text: String) -> String {
        let key = ([kind.rawValue] + sourceSegmentIDs.map(\.uuidString).sorted() + [MemoryText.normalized(text)])
            .joined(separator: "|")
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func merge(_ first: MemoryItem, _ second: MemoryItem) -> MemoryItem {
        guard first.id == second.id else { return first }

        var merged = first
        merged.review = latest(first.review, second.review)
        merged.edit = latest(first.edit, second.edit)
        return merged
    }

    private static func latest<Value>(_ first: Stamped<Value>?, _ second: Stamped<Value>?) -> Stamped<Value>? {
        switch (first, second) {
        case (nil, nil): nil
        case (let value?, nil): value
        case (nil, let value?): value
        case (let first?, let second?): .latest(first, second)
        }
    }
}

enum MemoryText {
    static func normalized(_ text: String) -> String {
        words(in: text).joined(separator: " ")
    }

    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
