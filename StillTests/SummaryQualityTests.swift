import Foundation
import Testing
@testable import Still

struct SummaryQualityTests {
    @Test
    func availabilityAndCapabilitiesAreNotActionItems() async throws {
        let segments = words("No tomorrow I will be on PTO for one day . All we'll be able to prove is that the user failed . I will send the release notes by Monday .")
        let note = try await ExtractiveNoteGenerator().note(template: .meeting, segments: segments)

        #expect(note.actions.map(\.text) == ["I will send the release notes by Monday ."])
    }

    @Test
    func beingAwayIsNotATaskEvenWhenItNamesWork() {
        #expect(!ExtractiveNoteGenerator.isAction("I will be out of office and review nothing until the release ."))
    }

    @Test
    func unresolvableReferencesDoNotBecomeStandaloneTasks() async throws {
        let segments = words("So we'll still do that . Yeah we'll have to do it tomorrow . Anna will send the release notes .")
        let note = try await ExtractiveNoteGenerator().note(template: .meeting, segments: segments)

        #expect(note.actions.map(\.text) == ["Anna will send the release notes ."])
    }

    @Test
    func fallbackSummaryPrioritizesOutcomesOverLongSmallTalk() async throws {
        let segments = words("Hello everybody I had a very lovely weekend walking through the countryside and visiting many different places with my friends . We agreed to delay the launch . Anna will send the updated schedule .")
        let note = try await ExtractiveNoteGenerator(summaryLimit: 2).note(template: .meeting, segments: segments)

        #expect(note.summary.count == 2)
        #expect(note.summary.allSatisfy { !$0.text.contains("weekend") })
    }

    @Test
    func constraintsRemainFactsInStructuredMemory() async throws {
        let source = ExtractionSegment(id: UUID(), start: 0, end: 4, text: "Tomorrow I will be on PTO for one day.", speaker: "Anna", language: "en")
        let candidates = try await ExtractiveExtractor().candidates(from: [source], language: "en")

        #expect(candidates.map(\.kind) == [.fact])
    }

    @Test
    func aQuestionHeavyTeamsCallStillUsesMeetingNotes() {
        let template = NoteTemplateSelector.template(
            segments: words("Which build ? Can we test tomorrow ? Who has a spare device ?"),
            duration: 1_090,
            tracks: [.microphone, .system]
        )

        #expect(template == .meeting)
    }

    @Test
    func existingCitationsCannotSupportAnUnrelatedModelClaim() async throws {
        let model = StubTextModel(output: #"{"summary":[{"text":"The board approved an acquisition","lines":[1]}],"decisions":[],"actions":[]}"#)
        let note = await GroundedNoteBuilder(preferred: LocalModelNoteGenerator(model: model)).note(
            segments: words("We agreed to ship on Friday ."),
            duration: 600,
            tracks: [.system]
        )

        #expect(!note.summary.contains { $0.text.contains("acquisition") })
    }

    @Test
    func aLargeMeetingStillProducesNotesWhenTheModelRejectsLargeInputs() async throws {
        let segments = (0..<30).map { index in
            TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 9), text: "The team confirmed delivery milestone number \(index) and will review the schedule before the next meeting.", language: "en", confidence: 0.95)
        }
        let note = try await LocalModelNoteGenerator(model: BoundedSummaryModel()).note(template: .meeting, segments: segments)

        #expect(!note.summary.isEmpty)
        #expect(NoteSchema.isGrounded(note, in: segments))
    }

    @Test
    func interruptedGenerationKeepsSuccessfulSectionsAndMarksTheFallback() async throws {
        let segments = (0..<50).map { index in
            TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 9), text: "The team confirmed delivery milestone number \(index) and will review the schedule before the next meeting.", language: "en", confidence: 0.95)
        }
        let note = try await LocalModelNoteGenerator(model: InterruptedSummaryModel()).note(template: .meeting, segments: segments)

        #expect(note.generation?.source == .mixed)
        #expect(note.generation?.problem != nil)
        #expect(note.summary.contains { $0.text == "The team confirmed delivery milestone" })
        #expect(NoteSchema.isGrounded(note, in: segments))
    }

    @Test
    func fallbackReasonSurvivesSavingTheNote() async throws {
        let note = await GroundedNoteBuilder(preferred: LocalModelNoteGenerator(model: FailingTextModel())).note(
            segments: words("We agreed to ship on Friday ."), duration: 600, tracks: [.system]
        )
        let saved = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))

        #expect(saved.generation?.source == .extractive)
        #expect(saved.generation?.problem != nil)
    }

    @Test
    func notesSavedBeforeGenerationProvenanceStillOpen() throws {
        let data = Data(#"{"template":"meeting","summary":[],"decisions":[],"actions":[],"userText":"My notes"}"#.utf8)
        let note = try JSONDecoder().decode(Note.self, from: data)

        #expect(note.userText == "My notes")
        #expect(note.generation == nil)
    }

}

private struct BoundedSummaryModel: ModelTextGenerator {
    struct InputTooLarge: Error {}

    func generate(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String {
        guard user.count <= 3_000 else { throw InputTooLarge() }
        return #"{"summary":[{"text":"The team confirmed delivery milestone","lines":[1]}],"decisions":[],"actions":[]}"#
    }
}


private actor InterruptedSummaryModel: ModelTextGenerator {
    var calls = 0

    func generate(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String {
        calls += 1
        guard calls == 1 else { throw BoundedSummaryModel.InputTooLarge() }
        return #"{"summary":[{"text":"The team confirmed delivery milestone","lines":[1]}],"decisions":[],"actions":[]}"#
    }
}
