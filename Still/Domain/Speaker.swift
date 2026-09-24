import Foundation

struct Speaker: Identifiable, Codable, Equatable, Sendable {
    enum NameSource: String, Codable, Sendable {
        case track
        case diarization
        case calendar
        case voiceProfile
        case owner
        case user
    }

    let id: UUID
    var name: String
    let origin: AudioTrack?
    let isYou: Bool
    var nameSource: NameSource?
    var voiceprint: Voiceprint?

    init(
        id: UUID = UUID(),
        name: String,
        origin: AudioTrack?,
        isYou: Bool,
        nameSource: NameSource? = nil,
        voiceprint: Voiceprint? = nil
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.isYou = isYou
        self.nameSource = nameSource
        self.voiceprint = voiceprint
    }

    var isNamedByUser: Bool {
        nameSource == .user
    }

    var isUnnamedGuest: Bool {
        guard !isYou else { return false }
        switch nameSource {
        case .none, .track, .diarization: return true
        case .calendar, .voiceProfile, .owner, .user: return false
        }
    }

    func named(_ name: String, by source: NameSource) -> Speaker {
        var copy = self
        copy.name = name
        copy.nameSource = source
        return copy
    }

    static func forTrack(_ track: AudioTrack) -> Speaker {
        switch track {
        case .microphone:
            Speaker(name: String(localized: "You"), origin: .microphone, isYou: true, nameSource: .track)
        case .system:
            Speaker(name: String(localized: "Other participants"), origin: .system, isYou: false, nameSource: .track)
        }
    }
}
