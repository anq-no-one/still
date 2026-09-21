import Foundation

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let revision: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let language: String?
    let confidence: Double?
    /// The recognizer's text is an immutable revision. A correction is stored
    /// beside it, so Still can always show what was actually heard.
    var correction: String?
    var speakerID: UUID?

    init(
        id: UUID = UUID(),
        revision: Int = 1,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        language: String?,
        confidence: Double?,
        correction: String? = nil,
        speakerID: UUID? = nil
    ) {
        self.id = id
        self.revision = revision
        self.start = start
        self.end = end
        self.text = text
        self.language = language
        self.confidence = confidence
        self.correction = correction
        self.speakerID = speakerID
    }

    var displayText: String {
        correction ?? text
    }

    var isCorrected: Bool {
        correction != nil
    }

    /// A recognizer that reports no confidence, or low confidence, leaves the
    /// segment marked uncertain. Still never rewrites it into confident text.
    var isUncertain: Bool {
        guard let confidence else { return true }
        return confidence < 0.5
    }

    var startText: String {
        start.recordingDurationText
    }

    func offset(by seconds: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            revision: revision,
            start: start + seconds,
            end: end + seconds,
            text: text,
            language: language,
            confidence: confidence,
            correction: correction,
            speakerID: speakerID
        )
    }

    func attributed(to speaker: Speaker) -> TranscriptSegment {
        var copy = self
        copy.speakerID = speaker.id
        return copy
    }
}

extension Array where Element == TranscriptSegment {
    var plainText: String {
        map(\.displayText).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
