import Foundation

enum NoteTemplateSelector {
    static let shortRecordingSeconds: TimeInterval = 180
    static let lectureSeconds: TimeInterval = 900
    static let interviewQuestionRatio = 0.15

    static func template(
        segments: [TranscriptSegment],
        duration: TimeInterval,
        tracks: [AudioTrack]
    ) -> NoteTemplate {
        guard !segments.isEmpty else { return .personalNote }

        if tracks.contains(.system) {
            return .meeting
        }
        if questionRatio(in: segments) >= interviewQuestionRatio {
            return .interview
        }
        if duration <= shortRecordingSeconds {
            return .personalNote
        }
        if duration >= lectureSeconds {
            return .lecture
        }
        return .meeting
    }

    private static func questionRatio(in segments: [TranscriptSegment]) -> Double {
        let terminators = segments.map(\.text).joined(separator: " ").filter { ".?!".contains($0) }
        guard !terminators.isEmpty else { return 0 }

        return Double(terminators.filter { $0 == "?" }.count) / Double(terminators.count)
    }
}
