import Foundation

enum EchoFilter {
    static let tolerance: TimeInterval = 1
    static let sharedWords = 0.6

    static func removingEcho(from segments: [TranscriptSegment], speakers: [Speaker]) -> [TranscriptSegment] {
        let microphone = Set(speakers.filter { $0.origin == .microphone }.map(\.id))
        let system = Set(speakers.filter { $0.origin == .system }.map(\.id))
        let heard = segments.filter { $0.speakerID.map(system.contains) ?? false }
        guard !heard.isEmpty else { return segments }

        return segments.filter { segment in
            guard let speaker = segment.speakerID, microphone.contains(speaker) else { return true }
            return !heard.contains { isEcho(segment, of: $0) }
        }
    }

    private static func isEcho(_ spoken: TranscriptSegment, of heard: TranscriptSegment) -> Bool {
        guard spoken.start <= heard.end + tolerance, heard.start <= spoken.end + tolerance else { return false }

        let words = Self.words(in: spoken.text)
        guard !words.isEmpty else { return true }
        return Double(words.intersection(Self.words(in: heard.text)).count) / Double(words.count) >= sharedWords
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
