import Foundation

struct Speaker: Identifiable, Codable, Equatable, Sendable {
    enum NameSource: String, Codable, Sendable {
        case track
        case diarization
        case calendar
        case voiceProfile
        case owner
        case user
        case callCue
        case spoken
        case roster
    }

    let id: UUID
    var name: String
    let origin: AudioTrack?
    let isYou: Bool
    var nameSource: NameSource?
    var voiceprint: Voiceprint?
    var suggestedName: String?

    init(
        id: UUID = UUID(),
        name: String,
        origin: AudioTrack?,
        isYou: Bool,
        nameSource: NameSource? = nil,
        voiceprint: Voiceprint? = nil,
        suggestedName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.isYou = isYou
        self.nameSource = nameSource
        self.voiceprint = voiceprint
        self.suggestedName = suggestedName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, origin, isYou, nameSource, voiceprint, suggestedName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        origin = try container.decodeIfPresent(AudioTrack.self, forKey: .origin)
        isYou = try container.decode(Bool.self, forKey: .isYou)
        nameSource = try? container.decodeIfPresent(NameSource.self, forKey: .nameSource)
        voiceprint = try container.decodeIfPresent(Voiceprint.self, forKey: .voiceprint)
        suggestedName = try container.decodeIfPresent(String.self, forKey: .suggestedName)
    }

    var isNamedByUser: Bool {
        nameSource == .user
    }

    var isUnnamedGuest: Bool {
        guard !isYou else { return false }
        switch nameSource {
        case .none, .track, .diarization: return true
        case .calendar, .voiceProfile, .owner, .user, .callCue, .spoken, .roster: return false
        }
    }

    func named(_ name: String, by source: NameSource) -> Speaker {
        var copy = self
        copy.name = name
        copy.nameSource = source
        copy.suggestedName = nil
        return copy
    }

    func suggesting(_ name: String) -> Speaker {
        var copy = self
        copy.suggestedName = name
        return copy
    }

    func confirmingSuggestedName() -> Speaker {
        guard let suggestedName else { return self }
        return named(suggestedName, by: .callCue)
    }

    func rejectingSuggestedName() -> Speaker {
        var copy = self
        copy.suggestedName = nil
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
