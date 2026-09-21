import Foundation

struct Speaker: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// The track this group came from. The microphone is the person holding the
    /// device, which is the one identity Still can claim from evidence.
    let origin: AudioTrack?
    let isYou: Bool

    init(id: UUID = UUID(), name: String, origin: AudioTrack?, isYou: Bool) {
        self.id = id
        self.name = name
        self.origin = origin
        self.isYou = isYou
    }

    static func forTrack(_ track: AudioTrack) -> Speaker {
        switch track {
        case .microphone:
            Speaker(name: String(localized: "You"), origin: .microphone, isYou: true)
        case .system:
            Speaker(name: String(localized: "Other participants"), origin: .system, isYou: false)
        }
    }
}
