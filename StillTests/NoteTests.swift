import Foundation
import Testing
@testable import Still

struct NoteTemplateSelectorTests {
    @Test
    func aSystemAudioTrackMeansAMeeting() {
        let template = NoteTemplateSelector.template(
            segments: words("We should ship it ."),
            duration: 600,
            tracks: [.microphone, .system]
        )

        #expect(template == .meeting)
    }

    @Test
    func manyQuestionsMeanAnInterview() {
        let template = NoteTemplateSelector.template(
            segments: words("What did you build ? How long did it take ? Fine ."),
            duration: 600,
            tracks: [.microphone]
        )

        #expect(template == .interview)
    }

    @Test
    func aShortSoloRecordingIsAVoiceNote() {
        let template = NoteTemplateSelector.template(
            segments: words("Remember to call the dentist ."),
            duration: 40,
            tracks: [.microphone]
        )

        #expect(template == .personalNote)
    }

    @Test
    func aLongSoloRecordingIsALecture() {
        let template = NoteTemplateSelector.template(
            segments: words("Today we cover gradient descent ."),
            duration: 3_600,
            tracks: [.microphone]
        )

        #expect(template == .lecture)
    }

    @Test
    func anEmptyTranscriptStaysAVoiceNote() {
        #expect(NoteTemplateSelector.template(segments: [], duration: 5_000, tracks: [.system]) == .personalNote)
    }
}

struct ExtractiveNoteGeneratorTests {
    @Test
    func everyClaimQuotesTheTranscriptAndNamesItsSegments() async throws {
        let segments = words("We decided to delay the launch . Anna will send the timeline by Friday .")

        let note = try await ExtractiveNoteGenerator().note(template: .meeting, segments: segments)

        #expect(NoteSchema.isGrounded(note, in: segments))
        #expect(note.decisions.map(\.text) == ["We decided to delay the launch ."])
        #expect(note.actions.map(\.text) == ["Anna will send the timeline by Friday ."])

        let quoted = note.generatedItems.map(\.text).joined(separator: " ")
        let spoken = segments.map(\.text).joined(separator: " ")
        #expect(quoted.split(separator: " ").allSatisfy { spoken.contains($0) })
    }

    @Test
    func summaryKeepsTranscriptOrder() async throws {
        let segments = words("First a very long opening statement about the plan . Short . Then another extended closing statement .")

        let note = try await ExtractiveNoteGenerator(summaryLimit: 2).note(template: .meeting, segments: segments)

        #expect(note.summary.count == 2)
        #expect(note.summary[0].text.hasPrefix("First"))
        #expect(note.summary[1].text.hasPrefix("Then"))
    }
}

struct GroundedNoteBuilderTests {
    @Test
    func keepsAGroundedGeneratedNote() async {
        let segments = words("We agreed to hire two engineers .")
        let generator = StubNoteGenerator { template, segments in
            Note(
                template: template,
                summary: [NoteItem(text: "Hiring agreed", sourceSegmentIDs: [segments[0].id])]
            )
        }

        let note = await GroundedNoteBuilder(preferred: generator).note(
            segments: segments,
            duration: 600,
            tracks: [.microphone]
        )

        #expect(note.summary.map(\.text) == ["Hiring agreed"])
    }

    @Test
    func replacesAnUngroundedNoteWithQuotedTranscript() async {
        let segments = words("We agreed to hire two engineers .")
        let generator = StubNoteGenerator { template, _ in
            Note(
                template: template,
                summary: [NoteItem(text: "The board approved a merger", sourceSegmentIDs: [UUID()])]
            )
        }

        let note = await GroundedNoteBuilder(preferred: generator).note(
            segments: segments,
            duration: 600,
            tracks: [.microphone]
        )

        #expect(!note.summary.contains { $0.text.contains("merger") })
        #expect(NoteSchema.isGrounded(note, in: segments))
    }

    @Test
    func replacesAFailedGeneratorWithQuotedTranscript() async {
        let segments = words("We agreed to hire two engineers .")
        let generator = StubNoteGenerator { _, _ in throw StubNoteGenerator.Unavailable() }

        let note = await GroundedNoteBuilder(preferred: generator).note(
            segments: segments,
            duration: 600,
            tracks: [.microphone]
        )

        #expect(NoteSchema.isGrounded(note, in: segments))
        #expect(!note.decisions.isEmpty)
    }

    @Test
    func rejectsAClaimWithNoSource() {
        let segments = words("Anything .")
        let note = Note(template: .meeting, summary: [NoteItem(text: "Claim", sourceSegmentIDs: [])])

        #expect(!NoteSchema.isGrounded(note, in: segments))
    }
}

struct StubNoteGenerator: NoteGenerator, @unchecked Sendable {
    struct Unavailable: Error {}

    let build: (NoteTemplate, [TranscriptSegment]) throws -> Note

    init(build: @escaping (NoteTemplate, [TranscriptSegment]) throws -> Note) {
        self.build = build
    }

    func note(template: NoteTemplate, segments: [TranscriptSegment]) async throws -> Note {
        try build(template, segments)
    }
}

func words(_ text: String) -> [TranscriptSegment] {
    text.split(separator: " ").enumerated().map { index, word in
        TranscriptSegment(
            start: TimeInterval(index),
            end: TimeInterval(index) + 1,
            text: String(word),
            language: "en",
            confidence: 0.9
        )
    }
}

struct EvidencePlaybackTests {
    private let tapped = UUID()
    private let other = UUID()

    @Test
    func tappingThePlayingRowPauses() {
        #expect(EvidencePlayback.shouldPause(tapped: tapped, playingID: tapped, playerIsPlaying: true))
        #expect(EvidencePlayback.isShowingPlaying(tapped, playingID: tapped, playerIsPlaying: true))
    }

    @Test
    func tappingAnotherRowStartsItInstead() {
        #expect(!EvidencePlayback.shouldPause(tapped: other, playingID: tapped, playerIsPlaying: true))
        #expect(!EvidencePlayback.isShowingPlaying(other, playingID: tapped, playerIsPlaying: true))
    }

    @Test
    func aPausedPlayerNeverShowsPlaying() {
        #expect(!EvidencePlayback.shouldPause(tapped: tapped, playingID: tapped, playerIsPlaying: false))
        #expect(!EvidencePlayback.isShowingPlaying(tapped, playingID: tapped, playerIsPlaying: false))
        #expect(!EvidencePlayback.isShowingPlaying(tapped, playingID: nil, playerIsPlaying: false))
    }
}
