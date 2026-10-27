import Foundation
import Testing
@testable import Still

struct NoteAttributionTests {
    private let anna = Speaker(name: "Anna Kowalska", origin: .system, isYou: false)
    private let ben = Speaker(name: "Ben Olsen", origin: .system, isYou: false)

    private func conversation() -> [TranscriptSegment] {
        words("Can you send the release notes ?").map { $0.attributed(to: anna) }
            + words("I will send the release notes by Monday .").map { $0.attributed(to: ben) }
    }

    @Test
    func aNoteItemNamesThePeopleWhoseLinesItCites() {
        let segments = conversation()
        let item = NoteItem(text: "Ben sends the release notes", sourceSegmentIDs: segments.suffix(3).map(\.id))

        #expect(item.speakerNames(segments: segments, speakers: [anna, ben]) == ["Ben Olsen"])
    }

    @Test
    func renamingASpeakerRenamesTheAttributionOnExistingNotes() {
        let segments = conversation()
        let item = NoteItem(text: "Ben sends the release notes", sourceSegmentIDs: segments.suffix(3).map(\.id))
        var renamed = ben
        renamed.name = "Benjamin Olsen"

        #expect(item.speakerNames(segments: segments, speakers: [anna, renamed]) == ["Benjamin Olsen"])
    }

    @Test
    func aSentenceNeverSpansTwoSpeakers() {
        let sentences = ExtractiveNoteGenerator.sentences(in: words("Sure").map { $0.attributed(to: anna) } + words("I will send it .").map { $0.attributed(to: ben) })

        #expect(sentences.map(\.text) == ["Sure", "I will send it ."])
    }

    @Test
    func theModelReadsWhoSaidEachLine() async throws {
        let model = PromptRecordingModel(output: #"{"summary":[{"text":"Ben will send the release notes by Monday","lines":[2]}],"decisions":[],"actions":[]}"#)

        _ = try await LocalModelNoteGenerator(model: model).note(template: .meeting, segments: conversation(), speakers: [anna, ben])

        let prompt = try #require(await model.prompts.first)
        #expect(prompt.contains("[1] Anna Kowalska: Can you send the release notes ?"))
        #expect(prompt.contains("[2] Ben Olsen: I will send the release notes by Monday ."))
    }

    @Test
    func aWindowWithNothingWorthNotingIsNotFilledWithQuotes() async throws {
        let segments = (0..<40).map { index in
            TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 9), text: "We agreed to keep milestone \(index) and the team will review the schedule before the next meeting.", language: "en", confidence: 0.95)
        }
        let note = try await LocalModelNoteGenerator(model: FirstWindowOnlyModel()).note(template: .meeting, segments: segments)

        #expect(note.generation?.source == .model)
        #expect(note.summary.map(\.text) == ["The team keeps its milestones"])
        #expect(note.decisions.isEmpty)
        #expect(note.actions.isEmpty)
    }

    @Test
    func theExportedTranscriptSaysWhoSpoke() {
        let recording = Recording(title: "Release", transcript: "", segments: conversation(), speakers: [anna, ben], duration: 20)

        let markdown = RecordingDocument.markdown(for: recording)

        #expect(markdown.contains("**Anna Kowalska:** Can you send the release notes ?"))
        #expect(markdown.contains("**Ben Olsen:** I will send the release notes by Monday ."))
    }
}

private actor PromptRecordingModel: ModelTextGenerator {
    let output: String
    private(set) var prompts: [String] = []

    init(output: String) {
        self.output = output
    }

    func generate(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String {
        prompts.append(user)
        return output
    }
}

private actor FirstWindowOnlyModel: ModelTextGenerator {
    private var calls = 0

    func generate(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String {
        calls += 1
        guard calls == 1 else { return #"{"summary":[],"decisions":[],"actions":[]}"# }
        return #"{"summary":[{"text":"The team keeps its milestones","lines":[1]}],"decisions":[],"actions":[]}"#
    }
}
