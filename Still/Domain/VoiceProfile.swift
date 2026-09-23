import Foundation

struct Voiceprint: Codable, Equatable, Sendable {
    let values: [Float]

    init?(_ values: [Float]) {
        let length = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0, length.isFinite else { return nil }
        self.values = values.map { $0 / length }
    }

    func distance(to other: Voiceprint) -> Float {
        guard values.count == other.values.count else { return .infinity }
        return 1 - zip(values, other.values).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func mean(_ prints: [Voiceprint]) -> Voiceprint? {
        guard let dimensions = prints.first?.values.count,
              prints.allSatisfy({ $0.values.count == dimensions })
        else { return nil }

        let sum = prints.reduce(into: [Float](repeating: 0, count: dimensions)) { total, print in
            for index in total.indices {
                total[index] += print.values[index]
            }
        }
        return Voiceprint(sum)
    }
}

struct VoiceProfile: Equatable, Sendable {
    let name: String
    let voiceprint: Voiceprint
    let evidence: Int
}

enum VoiceProfiles {
    static func from(_ recordings: [Recording]) -> [VoiceProfile] {
        let named = newestFirst(recordings).flatMap { recording in
            recording.speakers.filter { $0.isNamedByUser && $0.voiceprint != nil }
        }

        return Dictionary(grouping: named) { key(for: $0.name) }
            .compactMap { _, speakers in
                guard let voiceprint = Voiceprint.mean(speakers.compactMap(\.voiceprint)),
                      let newest = speakers.first
                else { return nil }
                return VoiceProfile(name: newest.name, voiceprint: voiceprint, evidence: speakers.count)
            }
            .sorted { $0.name < $1.name }
    }

    static func ownerName(in recordings: [Recording]) -> String? {
        newestFirst(recordings)
            .lazy
            .flatMap(\.speakers)
            .first { $0.isYou && $0.isNamedByUser }?
            .name
    }

    static func key(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func newestFirst(_ recordings: [Recording]) -> [Recording] {
        recordings.filter { !$0.isDeleted }.sorted { $0.createdAt > $1.createdAt }
    }
}

struct VoiceMatcher {
    static let maximumDistance: Float = 0.45
    static let minimumMargin: Float = 0.08

    let profiles: [VoiceProfile]

    func matches(for speakers: [Speaker]) -> [UUID: VoiceProfile] {
        let candidates = speakers.compactMap { speaker -> (speaker: UUID, profile: VoiceProfile, distance: Float)? in
            guard let voiceprint = speaker.voiceprint else { return nil }

            let ranked = profiles
                .map { (profile: $0, distance: $0.voiceprint.distance(to: voiceprint)) }
                .sorted { $0.distance < $1.distance }
            guard let best = ranked.first, best.distance <= Self.maximumDistance else { return nil }
            if ranked.count > 1, ranked[1].distance - best.distance < Self.minimumMargin { return nil }
            return (speaker.id, best.profile, best.distance)
        }

        var matches: [UUID: VoiceProfile] = [:]
        var claimed = Set<String>()
        for candidate in candidates.sorted(by: { $0.distance < $1.distance }) {
            let name = VoiceProfiles.key(for: candidate.profile.name)
            guard !claimed.contains(name) else { continue }
            claimed.insert(name)
            matches[candidate.speaker] = candidate.profile
        }
        return matches
    }
}
