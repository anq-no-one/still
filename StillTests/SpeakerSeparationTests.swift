import Foundation
import SwiftData
import Testing
@testable import Still

struct SpeakerSeparationTests {
    private let you = Speaker.forTrack(.microphone)
    private let others = Speaker.forTrack(.system)

    @Test
    func givesEachSegmentToTheVoiceThatSpokeMostOfIt() async {
        let transcription = call([
            (0, 4, "Welcome everyone", others),
            (4, 9, "Thanks for having me", others),
            (9, 12, "Let us start", you),
        ])
        let diarizer = StubDiarizer(turns: [
            SpeakerTurn(speaker: 0, start: 0, end: 4.5),
            SpeakerTurn(speaker: 1, start: 4.5, end: 9),
        ])

        let result = await SpeakerSeparation(diarizer: diarizer).separate(transcription, tracks: callTracks)

        #expect(result.speakers.map(\.name) == ["You", "Speaker 1", "Speaker 2"])
        let speaker1 = result.speakers[1]
        let speaker2 = result.speakers[2]
        #expect(result.segments.map(\.speakerID) == [speaker1.id, speaker2.id, you.id])
        #expect(result.segments.map(\.id) == transcription.segments.map(\.id))
        #expect(!speaker1.isYou)
        #expect(speaker1.origin == .system)
    }

    @Test
    func timesTurnsAgainstTheWholeRecording() async {
        let transcription = call([
            (10, 12, "First voice", others),
            (13, 15, "Second voice", others),
        ])
        let late = [
            CapturedTrack(track: .microphone, format: .transcription, startOffset: 0, pcm: audio),
            CapturedTrack(track: .system, format: .transcription, startOffset: 10, pcm: audio),
        ]
        let diarizer = StubDiarizer(turns: [
            SpeakerTurn(speaker: 0, start: 0, end: 2),
            SpeakerTurn(speaker: 1, start: 3, end: 5),
        ])

        let result = await SpeakerSeparation(diarizer: diarizer).separate(transcription, tracks: late)

        #expect(result.speakers.map(\.name) == ["You", "Speaker 1", "Speaker 2"])
    }

    @Test
    func aSegmentJustOutsideATurnJoinsTheNearestVoiceAndAFarOneKeepsItsGroup() async {
        let transcription = call([
            (0, 2, "Hello", others),
            (2.5, 3, "Right", others),
            (5, 6, "Hi", others),
            (20, 21, "Unheard", others),
        ])
        let diarizer = StubDiarizer(turns: [
            SpeakerTurn(speaker: 0, start: 0, end: 2),
            SpeakerTurn(speaker: 1, start: 5, end: 6),
        ])

        let result = await SpeakerSeparation(diarizer: diarizer).separate(transcription, tracks: callTracks)

        #expect(result.speakers.map(\.name) == ["You", "Other participants", "Speaker 1", "Speaker 2"])
        #expect(result.segments[1].speakerID == result.segments[0].speakerID)
        #expect(result.segments[3].speakerID == others.id)
    }

    @Test
    func oneVoiceKeepsTheTrackGroupAndRemembersItsVoiceprint() async throws {
        let transcription = call([(0, 3, "Just me on the line", others)])
        let diarizer = StubDiarizer(turns: [SpeakerTurn(speaker: 0, start: 0, end: 3)])
        let prints = StubVoiceprints(prints: [0: try #require(Voiceprint([1, 0, 0]))])

        let result = await SpeakerSeparation(diarizer: diarizer, voiceprints: prints).separate(transcription, tracks: callTracks)

        #expect(result.speakers.map(\.id) == [you.id, others.id])
        #expect(result.speakers[1].voiceprint == Voiceprint([1, 0, 0]))
        #expect(result.segments == transcription.segments)
    }

    @Test
    func aFailingDiarizerLeavesTheTrackGroupsUntouched() async {
        let transcription = call([(0, 3, "Hello", others), (3, 6, "Hi", others)])

        let result = await SpeakerSeparation(diarizer: StubDiarizer(error: StubDiarizer.Failure()))
            .separate(transcription, tracks: callTracks)

        #expect(result == transcription)
    }

    @Test
    func aMissingModelPackLeavesTheTrackGroupsUntouched() async throws {
        let transcription = call([(0, 3, "Hello", others), (3, 6, "Hi", others)])
        let root = try Scratch().directory
        let diarizer = FluidSpeakerDiarizer(pack: ModelCatalog.speakerSeparation, root: root)

        await #expect(throws: SpeakerSeparationError.self) {
            try await diarizer.turns(in: [0, 0, 0], sampleRate: 16_000)
        }
        let result = await SpeakerSeparation(diarizer: diarizer).separate(transcription, tracks: callTracks)

        #expect(result == transcription)
    }

    @Test
    func splitsTheCallAudioAndKeepsTheMicrophoneAsYou() {
        #expect(SpeakerSeparation.roomTrack(in: callTracks)?.track == .system)
    }

    @Test
    func withoutCallAudioTheMicrophoneIsTheRoom() {
        let tracks = [
            CapturedTrack(track: .microphone, format: .transcription, startOffset: 0, pcm: audio),
            CapturedTrack(track: .system, format: .transcription, startOffset: 0, pcm: Data()),
        ]

        #expect(SpeakerSeparation.roomTrack(in: tracks)?.track == .microphone)
    }

    @Test
    func aFullSmallMeetingGoesToTheLargeMeetingModel() async throws {
        let four = (0..<4).map { SpeakerTurn(speaker: $0, start: Double($0), end: Double($0) + 1) }
        let six = (0..<6).map { SpeakerTurn(speaker: $0, start: Double($0), end: Double($0) + 1) }

        let turns = try await AutomaticSpeakerDiarizer(
            smallMeeting: StubDiarizer(turns: four),
            largeMeeting: StubDiarizer(turns: six)
        ).turns(in: [], sampleRate: 16_000)

        #expect(turns == six)
    }

    @Test
    func threeRemoteVoicesAreCheckedWithTheLargeMeetingModel() async throws {
        let three = (0..<3).map { SpeakerTurn(speaker: $0, start: Double($0), end: Double($0) + 1) }
        let four = (0..<4).map { SpeakerTurn(speaker: $0, start: Double($0), end: Double($0) + 1) }
        let large = StubDiarizer(turns: four)

        let turns = try await AutomaticSpeakerDiarizer(
            smallMeeting: StubDiarizer(turns: three),
            largeMeeting: large
        ).turns(in: [], sampleRate: 16_000)

        #expect(large.calls == 1)
        #expect(turns == four)
    }

    @Test
    func aSmallMeetingStaysWithTheSmallMeetingModel() async throws {
        let two = [SpeakerTurn(speaker: 0, start: 0, end: 1), SpeakerTurn(speaker: 1, start: 1, end: 2)]
        let large = StubDiarizer(turns: [])

        let turns = try await AutomaticSpeakerDiarizer(smallMeeting: StubDiarizer(turns: two), largeMeeting: large)
            .turns(in: [], sampleRate: 16_000)

        #expect(turns == two)
        #expect(large.calls == 0)
    }

    @Test
    func aFailingLargeMeetingModelKeepsTheSmallMeetingResult() async throws {
        let four = (0..<4).map { SpeakerTurn(speaker: $0, start: Double($0), end: Double($0) + 1) }

        let turns = try await AutomaticSpeakerDiarizer(
            smallMeeting: StubDiarizer(turns: four),
            largeMeeting: StubDiarizer(error: StubDiarizer.Failure())
        ).turns(in: [], sampleRate: 16_000)

        #expect(turns == four)
    }

    @Test
    func aFailingSmallMeetingModelStillAllowsTheLargeModelToSeparateVoices() async throws {
        let four = (0..<4).map { SpeakerTurn(speaker: $0, start: Double($0), end: Double($0) + 1) }

        let turns = try await AutomaticSpeakerDiarizer(
            smallMeeting: StubDiarizer(error: StubDiarizer.Failure()),
            largeMeeting: StubDiarizer(turns: four)
        ).turns(in: [], sampleRate: 16_000)

        #expect(turns == four)
    }

    @Test
    func aLargeModelThatLosesVoicesDoesNotEraseTheSmallModelResult() async throws {
        let three = (0..<3).map { SpeakerTurn(speaker: $0, start: Double($0), end: Double($0) + 1) }

        let turns = try await AutomaticSpeakerDiarizer(
            smallMeeting: StubDiarizer(turns: three),
            largeMeeting: StubDiarizer(turns: [])
        ).turns(in: [], sampleRate: 16_000)

        #expect(turns == three)
    }

    @Test
    func voiceClipsPreferTheLongestTurnsAndStopAtTenSeconds() {
        let turns = [
            SpeakerTurn(speaker: 0, start: 0, end: 1),
            SpeakerTurn(speaker: 0, start: 2, end: 5),
            SpeakerTurn(speaker: 0, start: 10, end: 30),
        ]

        let ranges = VoiceClips.ranges(for: turns, sampleRate: 10, sampleCount: 250)

        #expect(ranges == [100..<200, 20..<50])
    }

    private var callTracks: [CapturedTrack] {
        [
            CapturedTrack(track: .microphone, format: .transcription, startOffset: 0, pcm: audio),
            CapturedTrack(track: .system, format: .transcription, startOffset: 0, pcm: audio),
        ]
    }

    private var audio: Data {
        Data(repeating: 1, count: AudioFormat.transcription.bytesPerSecond)
    }

    @Test
    func aSliverVoiceBelowOneSecondReturnsItsLinesToTheGroup() async {
        let transcription = call([
            (0, 6, "The plan for this week", others),
            (6, 6.4, "Yeah", others),
        ])
        let diarizer = StubDiarizer(turns: [
            SpeakerTurn(speaker: 0, start: 0, end: 6),
            SpeakerTurn(speaker: 1, start: 6, end: 6.4),
        ])

        let result = await SpeakerSeparation(diarizer: diarizer).separate(transcription, tracks: callTracks)

        #expect(result.speakers.map(\.name) == ["You", "Other participants", "Speaker 1"])
        #expect(result.segments[0].speakerID != others.id)
        #expect(result.segments[1].speakerID == others.id)
    }

    @Test
    func nearIdenticalVoiceprintsMergeIntoOneSpeaker() async throws {
        let transcription = call([
            (0, 4, "Welcome everyone", others),
            (4, 8, "Thanks for having me", others),
        ])
        let diarizer = StubDiarizer(turns: [
            SpeakerTurn(speaker: 0, start: 0, end: 4),
            SpeakerTurn(speaker: 1, start: 4, end: 8),
        ])
        let prints = StubVoiceprints(prints: [
            0: try #require(Voiceprint([1, 0, 0])),
            1: try #require(Voiceprint([0.99, 0.01, 0])),
        ])

        let result = await SpeakerSeparation(diarizer: diarizer, voiceprints: prints)
            .separate(transcription, tracks: callTracks)

        #expect(result.speakers.map(\.name) == ["You", "Speaker 1"])
        #expect(result.segments.map(\.speakerID) == [result.speakers[1].id, result.speakers[1].id])
    }

    @Test
    func distinctVoiceprintsStaySeparate() async throws {
        let transcription = call([
            (0, 4, "Welcome everyone", others),
            (4, 8, "Thanks for having me", others),
        ])
        let diarizer = StubDiarizer(turns: [
            SpeakerTurn(speaker: 0, start: 0, end: 4),
            SpeakerTurn(speaker: 1, start: 4, end: 8),
        ])
        let prints = StubVoiceprints(prints: [
            0: try #require(Voiceprint([1, 0, 0])),
            1: try #require(Voiceprint([0, 1, 0])),
        ])

        let result = await SpeakerSeparation(diarizer: diarizer, voiceprints: prints)
            .separate(transcription, tracks: callTracks)

        #expect(result.speakers.map(\.name) == ["You", "Speaker 1", "Speaker 2"])
    }

    @Test
    func aFullyClaimedGroupLeavesNoOtherParticipantsBehind() async {
        let transcription = call([
            (0, 4, "Welcome everyone", others),
            (4, 8, "Thanks for having me", others),
        ])
        let diarizer = StubDiarizer(turns: [
            SpeakerTurn(speaker: 0, start: 0, end: 4),
            SpeakerTurn(speaker: 1, start: 4, end: 8),
        ])

        let result = await SpeakerSeparation(diarizer: diarizer).separate(transcription, tracks: callTracks)

        #expect(result.speakers.map(\.name) == ["You", "Speaker 1", "Speaker 2"])
        #expect(!result.segments.contains { $0.speakerID == others.id })
    }

    private func call(_ lines: [(TimeInterval, TimeInterval, String, Speaker)]) -> TranscriptionResult {
        TranscriptionResult(
            segments: lines.map { start, end, text, speaker in
                TranscriptSegment(start: start, end: end, text: text, language: "en", confidence: 0.9)
                    .attributed(to: speaker)
            },
            speakers: [you, others]
        )
    }
}

@MainActor
struct DiarizedSpeakerRenameTests {
    @Test
    func renamingOneSeparatedSpeakerKeepsEveryoneElseAndTheTranscript() async throws {
        let others = Speaker.forTrack(.system)
        let transcription = TranscriptionResult(
            segments: [
                TranscriptSegment(start: 0, end: 2, text: "Morning", language: "en", confidence: 0.9).attributed(to: others),
                TranscriptSegment(start: 3, end: 5, text: "Hello", language: "en", confidence: 0.9).attributed(to: others),
            ],
            speakers: [others]
        )
        let diarizer = StubDiarizer(turns: [
            SpeakerTurn(speaker: 0, start: 0, end: 2),
            SpeakerTurn(speaker: 1, start: 3, end: 5),
        ])
        let tracks = [CapturedTrack(track: .system, format: .transcription, startOffset: 0, pcm: Data(repeating: 1, count: 64))]
        let separated = await SpeakerSeparation(diarizer: diarizer).separate(transcription, tracks: tracks)

        let library = try await makeLibrary()
        let recording = Recording(
            title: "Call",
            transcript: separated.segments.plainText,
            segments: separated.segments,
            speakers: separated.speakers,
            duration: 5
        )
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)
        let second = separated.speakers[1]

        editor.renameSpeaker(second, to: "Anna Kowalska")
        editor.saveNow()

        #expect(editor.recording.speakers.map(\.name) == ["Speaker 1", "Anna Kowalska"])
        #expect(editor.recording.speakers[1].id == second.id)
        #expect(editor.recording.speakers[1].isNamedByUser)
        #expect(editor.recording.segments == separated.segments)
        #expect(editor.speaker(of: separated.segments[1])?.name == "Anna Kowalska")
        #expect(library.recordings.first?.speakers.map(\.name) == ["Speaker 1", "Anna Kowalska"])
    }

    private func makeLibrary() async throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: try Scratch().directory,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        return library
    }
}

final class StubDiarizer: SpeakerDiarizer, @unchecked Sendable {
    struct Failure: Error {}

    private let turns: [SpeakerTurn]
    private let error: Error?
    private(set) var calls = 0

    init(turns: [SpeakerTurn] = [], error: Error? = nil) {
        self.turns = turns
        self.error = error
    }

    func turns(in samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn] {
        calls += 1
        if let error { throw error }
        return turns
    }
}

struct StubVoiceprints: VoiceprintExtractor {
    let prints: [Int: Voiceprint]

    func voiceprints(for turns: [SpeakerTurn], in samples: [Float], sampleRate: Int) async throws -> [Int: Voiceprint] {
        prints
    }
}
