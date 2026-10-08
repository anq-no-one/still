import Foundation
import Testing
@testable import Still

struct StubTextModel: ModelTextGenerator {
    let output: String

    func generate(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String {
        output
    }
}

struct FailingTextModel: ModelTextGenerator {
    struct Unavailable: Error {}

    func generate(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String {
        throw Unavailable()
    }
}

struct LocalModelTitleTests {
    private func segments(_ text: String) -> TitleRequest {
        TitleRequest(segments: words(text), calendarTitle: nil, language: "en")
    }

    @Test
    func aValidTitleIsKept() async {
        let title = await LocalModelTitle(model: StubTextModel(output: #"{"title":"Quarterly plan"}"#))
            .title(for: segments("We discussed the quarterly plan today ."))

        #expect(title == "Quarterly plan")
    }

    @Test
    func anEmptyTranscriptNeedsNoModel() async {
        let model = StubTextModel(output: #"{"title":"Anything"}"#)

        #expect(await LocalModelTitle(model: model).title(for: TitleRequest(segments: [], calendarTitle: nil, language: nil)) == nil)
    }

    @Test
    func badOutputFallsBackToExtractive() async {
        for output in [#"{"title":""}"#, #"{"title":"Nope"#, "{}", "[]"] {
            let title = await LocalModelTitle(model: StubTextModel(output: output))
                .title(for: segments("We discussed the quarterly plan ."))

            #expect(title == nil, "output: \(output)")
        }
    }

    @Test
    func theFirstGeneratorWithAUsableTitleWins() async {
        let title = await TitleChain.first(of: [
            { _ in nil },
            { _ in "Hey, how are you?" },
            { _ in "Onboarding Screens Review" },
            { _ in "Too Late" },
        ], for: segments("We review the onboarding screens ."))

        #expect(title == "Onboarding Screens Review")
    }

    @Test
    func anOverlongTitleIsRejected() async {
        let title = await LocalModelTitle(
            model: StubTextModel(output: #"{"title":"This title keeps going well past the fifty two character limit"}"#)
        ).title(for: segments("We discussed the quarterly plan ."))

        #expect(title == nil)
    }

    @Test
    func theTitleSchemaIsAClosedObject() throws {
        let data = try #require(LocalModelTitle<StubTextModel>.schema.data(using: .utf8))
        let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])

        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(properties.keys.sorted() == ["title"])
    }
}

struct LocalModelNoteGeneratorTests {
    private func meeting() -> [TranscriptSegment] {
        words("We agreed to ship on Friday . Anna will send the notes .")
    }

    @Test
    func lineCitationsBecomeSegmentIDs() async throws {
        let segments = meeting()
        let output = """
            {"summary":[{"text":"Ship on Friday","lines":[1]}],"decisions":[],"actions":[]}
            """
        let note = try await LocalModelNoteGenerator(model: StubTextModel(output: output))
            .note(template: .meeting, segments: segments)

        #expect(note.summary.map(\.text) == ["Ship on Friday"])
        #expect(NoteSchema.isGrounded(note, in: segments))
    }

    @Test
    func linesOutsideTheTranscriptAreDropped() async throws {
        let output = """
            {"summary":[{"text":"Ship on Friday","lines":[99]}],"decisions":[],"actions":[{"text":"Notes","lines":[2]}]}
            """
        let note = try await LocalModelNoteGenerator(model: StubTextModel(output: output))
            .note(template: .meeting, segments: meeting())

        #expect(note.summary.isEmpty)
        #expect(note.actions.map(\.text) == ["Notes"])
    }

    @Test
    func anEmptyModelAnswerThrowsSoExtractiveQuotesInstead() async {
        let output = #"{"summary":[],"decisions":[],"actions":[]}"#

        await #expect(throws: LocalModelNoteGenerator<StubTextModel>.NoGroundedItems.self) {
            try await LocalModelNoteGenerator(model: StubTextModel(output: output))
                .note(template: .meeting, segments: meeting())
        }
    }

    @Test
    func invalidJSONThrowsSoExtractiveQuotesInstead() async {
        await #expect(throws: (any Error).self) {
            try await LocalModelNoteGenerator(model: StubTextModel(output: "not json"))
                .note(template: .meeting, segments: meeting())
        }
    }

    @Test
    func anEmptyTranscriptReturnsAnEmptyNote() async throws {
        let note = try await LocalModelNoteGenerator(model: StubTextModel(output: "{}"))
            .note(template: .meeting, segments: [])

        #expect(note == Note(template: .meeting))
    }

    @Test
    func theNoteSchemaNamesAllThreeLists() throws {
        let data = try #require(LocalModelNoteGenerator<StubTextModel>.schema.data(using: .utf8))
        let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])

        #expect(properties.keys.sorted() == ["actions", "decisions", "summary"])
        #expect((schema["required"] as? [String])?.sorted() == ["actions", "decisions", "summary"])
    }

    @Test
    func aGroundedModelNoteSurvivesTheBuilder() async {
        let segments = meeting()
        let preferred = LocalModelNoteGenerator(
            model: StubTextModel(output: """
                {"summary":[{"text":"Ship on Friday","lines":[1]}],"decisions":[],"actions":[]}
                """)
        )

        let note = await GroundedNoteBuilder(preferred: preferred).note(
            segments: segments,
            duration: 600,
            tracks: [.microphone]
        )

        #expect(note.summary.map(\.text) == ["Ship on Friday"])
    }
}

@MainActor
struct RecordingFinalizerTitleTests {
    private func finalizer(
        library: SpyRecordingLibrary,
        makeTitle: (@MainActor @Sendable (TitleRequest) async -> String?)?
    ) -> RecordingFinalizer {
        RecordingFinalizer(
            finalTranscription: FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600),
            speakerSeparation: .trackBased,
            noteBuilder: GroundedNoteBuilder(),
            library: library,
            makeTitle: makeTitle
        )
    }

    @Test
    func aModelTitleWinsOverTheFirstWords() async throws {
        let library = SpyRecordingLibrary()
        let draft = RecordingFinalizer.Draft(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), duration: 5)

        let recording = try await finalizer(library: library, makeTitle: { _ in "Quarterly plan" }).build(draft)

        #expect(recording.title == "Quarterly plan")
    }

    @Test
    func aMissingModelTitleFallsBackToTheFirstWords() async throws {
        let library = SpyRecordingLibrary()
        let draft = RecordingFinalizer.Draft(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), duration: 5)

        let recording = try await finalizer(library: library, makeTitle: nil).build(draft)

        #expect(recording.title == "Transcribed after saving")
    }

    @Test
    func aDraftTitleIsNeverOverwritten() async throws {
        let library = SpyRecordingLibrary()
        var draft = RecordingFinalizer.Draft(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), duration: 5)
        draft.title = "Kept title"

        let recording = try await finalizer(library: library, makeTitle: { _ in "Model title" }).build(draft)

        #expect(recording.title == "Kept title")
    }
}
