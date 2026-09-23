import Foundation

struct SpeakerTurn: Equatable, Sendable {
    let speaker: Int
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        end - start
    }

    func offset(by seconds: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(speaker: speaker, start: start + seconds, end: end + seconds)
    }

    func overlap(with segment: TranscriptSegment) -> TimeInterval {
        max(0, min(end, segment.end) - max(start, segment.start))
    }

    func distance(to segment: TranscriptSegment) -> TimeInterval {
        max(0, max(start, segment.start) - min(end, segment.end))
    }
}

protocol SpeakerDiarizer: Sendable {
    func turns(in samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn]
}

protocol VoiceprintExtractor: Sendable {
    func voiceprints(for turns: [SpeakerTurn], in samples: [Float], sampleRate: Int) async throws -> [Int: Voiceprint]
}

enum SpeakerSeparationError: Error {
    case modelNotInstalled
    case unsupportedSampleRate
}

struct SpeakerNamingContext: Sendable {
    var profiles: [VoiceProfile] = []
    var participants: [String] = []
    var ownerName: String?

    static let none = SpeakerNamingContext()
}

struct SpeakerSeparation: Sendable {
    let diarizer: SpeakerDiarizer?
    let voiceprints: VoiceprintExtractor?

    init(diarizer: SpeakerDiarizer?, voiceprints: VoiceprintExtractor? = nil) {
        self.diarizer = diarizer
        self.voiceprints = voiceprints
    }

    static let trackBased = SpeakerSeparation(diarizer: nil)

    func separate(
        _ transcription: TranscriptionResult,
        tracks: [CapturedTrack],
        naming context: SpeakerNamingContext = .none
    ) async -> TranscriptionResult {
        let separated = await diarized(transcription, tracks: tracks)
        return TranscriptionResult(
            segments: separated.segments,
            speakers: SpeakerNaming.name(separated.speakers, context: context)
        )
    }

    private func diarized(_ transcription: TranscriptionResult, tracks: [CapturedTrack]) async -> TranscriptionResult {
        guard let diarizer,
              let track = Self.roomTrack(in: tracks),
              let group = transcription.speakers.first(where: { $0.origin == track.track })
        else { return transcription }

        do {
            let samples = PCMSamples.floats(fromInt16: track.pcm, channels: track.format.channels)
            let rate = track.format.sampleRate
            let turns = try await diarizer.turns(in: samples, sampleRate: rate)
            let prints = (try? await voiceprints?.voiceprints(for: turns, in: samples, sampleRate: rate)) ?? [:]
            return SpeakerAssignment.assign(
                turns.map { $0.offset(by: track.startOffset) },
                voiceprints: prints,
                splitting: group,
                in: transcription
            )
        } catch {
            return transcription
        }
    }

    static func roomTrack(in tracks: [CapturedTrack]) -> CapturedTrack? {
        tracks.first { $0.track == .system && !$0.pcm.isEmpty }
            ?? tracks.first { $0.track == .microphone && !$0.pcm.isEmpty }
    }
}

enum SpeakerAssignment {
    static let tolerance: TimeInterval = 1

    static func assign(
        _ turns: [SpeakerTurn],
        voiceprints: [Int: Voiceprint] = [:],
        splitting group: Speaker,
        in transcription: TranscriptionResult
    ) -> TranscriptionResult {
        var matches: [UUID: Int] = [:]
        for segment in transcription.segments where segment.speakerID == group.id {
            if let speaker = speaker(for: segment, among: turns) {
                matches[segment.id] = speaker
            }
        }

        let order = transcription.segments.compactMap { matches[$0.id] }.uniqued()
        guard order.count > 1 else {
            return recognizing(group, by: order.first.flatMap { voiceprints[$0] }, in: transcription)
        }

        let people = Dictionary(uniqueKeysWithValues: order.enumerated().map { position, speaker in
            (speaker, Speaker(
                name: String(localized: "Speaker \(position + 1)"),
                origin: group.origin,
                isYou: false,
                nameSource: .diarization,
                voiceprint: voiceprints[speaker]
            ))
        })

        let segments = transcription.segments.map { segment in
            matches[segment.id].flatMap { people[$0] }.map(segment.attributed(to:)) ?? segment
        }

        let keepsGroup = segments.contains { $0.speakerID == group.id }
        let speakers = transcription.speakers.flatMap { speaker -> [Speaker] in
            guard speaker.id == group.id else { return [speaker] }
            let split = order.compactMap { people[$0] }
            return keepsGroup ? [speaker] + split : split
        }

        return TranscriptionResult(segments: segments, speakers: speakers)
    }

    private static func recognizing(
        _ group: Speaker,
        by voiceprint: Voiceprint?,
        in transcription: TranscriptionResult
    ) -> TranscriptionResult {
        guard let voiceprint else { return transcription }

        var result = transcription
        result.speakers = transcription.speakers.map { speaker in
            guard speaker.id == group.id else { return speaker }
            var recognized = speaker
            recognized.voiceprint = voiceprint
            return recognized
        }
        return result
    }

    private static func speaker(for segment: TranscriptSegment, among turns: [SpeakerTurn]) -> Int? {
        let overlaps = Dictionary(turns.map { ($0.speaker, $0.overlap(with: segment)) }, uniquingKeysWith: +)
        if let longest = overlaps.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }), longest.value > 0 {
            return longest.key
        }

        return turns
            .filter { $0.distance(to: segment) <= tolerance }
            .min { $0.distance(to: segment) < $1.distance(to: segment) }?
            .speaker
    }
}

enum SpeakerNaming {
    static func name(_ speakers: [Speaker], context: SpeakerNamingContext) -> [Speaker] {
        var named = speakers.map { speaker in
            guard speaker.isYou, !speaker.isNamedByUser, let owner = context.ownerName else { return speaker }
            return speaker.named(owner, by: .owner)
        }

        let recognized = VoiceMatcher(profiles: context.profiles).matches(for: named.filter(\.isUnnamedGuest))
        named = named.map { speaker in
            recognized[speaker.id].map { speaker.named($0.name, by: .voiceProfile) } ?? speaker
        }

        let taken = Set((named.map(\.name) + [context.ownerName].compactMap { $0 }).map(VoiceProfiles.key(for:)))
        let expected = context.participants
            .filter { !taken.contains(VoiceProfiles.key(for: $0)) }
            .uniqued()
        let guests = named.filter(\.isUnnamedGuest)
        guard guests.count == 1, expected.count == 1, let guest = guests.first, let name = expected.first else {
            return named
        }

        return named.map { $0.id == guest.id ? $0.named(name, by: .calendar) : $0 }
    }
}

struct AutomaticSpeakerDiarizer: SpeakerDiarizer {
    static let smallMeetingSeats = 4

    let smallMeeting: SpeakerDiarizer
    let largeMeeting: SpeakerDiarizer

    func turns(in samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn] {
        let small = try await smallMeeting.turns(in: samples, sampleRate: sampleRate)
        guard Set(small.map(\.speaker)).count >= Self.smallMeetingSeats else { return small }

        return (try? await largeMeeting.turns(in: samples, sampleRate: sampleRate)) ?? small
    }
}

enum VoiceClips {
    static let shortest: TimeInterval = 1.5
    static let longest: TimeInterval = 10
    static let perSpeaker = 3

    static func ranges(for turns: [SpeakerTurn], sampleRate: Int, sampleCount: Int) -> [Range<Int>] {
        turns
            .filter { $0.duration >= shortest }
            .sorted { $0.duration > $1.duration }
            .prefix(perSpeaker)
            .compactMap { turn in
                let start = max(0, Int(turn.start * TimeInterval(sampleRate)))
                let end = min(sampleCount, start + Int(min(turn.duration, longest) * TimeInterval(sampleRate)))
                return start < end ? start..<end : nil
            }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
