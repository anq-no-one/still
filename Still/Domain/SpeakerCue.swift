import Foundation

struct SpeakerCue: Equatable, Sendable {
    let name: String
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        max(0, end - start)
    }
}

struct SpeakerCueLog: Sendable {
    private var speaking: [String: (name: String, start: TimeInterval)] = [:]
    private var finished: [SpeakerCue] = []

    mutating func began(_ name: String, at offset: TimeInterval) {
        let key = VoiceProfiles.key(for: name)
        guard !key.isEmpty, speaking[key] == nil else { return }
        speaking[key] = (name, max(0, offset))
    }

    mutating func ended(_ name: String, at offset: TimeInterval) {
        guard let open = speaking.removeValue(forKey: VoiceProfiles.key(for: name)) else { return }
        finished.append(SpeakerCue(name: open.name, start: open.start, end: max(open.start, offset)))
    }

    func cues(closingAt offset: TimeInterval) -> [SpeakerCue] {
        let stillSpeaking = speaking.values.map { SpeakerCue(name: $0.name, start: $0.start, end: max($0.start, offset)) }
        return (finished + stillSpeaking).sorted { ($0.start, $0.name) < ($1.start, $1.name) }
    }
}
