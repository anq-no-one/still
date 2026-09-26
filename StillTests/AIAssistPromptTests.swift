import Foundation
import Testing
@testable import Still

struct AIAssistPromptTests {
    @Test
    func promptCarriesTheActionItemsToAchieve() {
        let note = Note(
            template: .meeting,
            summary: [NoteItem(text: "Alan joined the project.", sourceSegmentIDs: [])],
            decisions: [NoteItem(text: "Ship on Friday.", sourceSegmentIDs: [])],
            actions: [NoteItem(text: "Email the summary to Alan.", sourceSegmentIDs: [])],
            userText: "Ask about the budget next time."
        )

        let prompt = AIAssistPrompt.prompt(note: note, title: "Weekly Call", recordedAt: Date(timeIntervalSince1970: 0))

        #expect(prompt.contains("Weekly Call"))
        #expect(prompt.contains("Email the summary to Alan."))
        #expect(prompt.contains("Alan joined the project."))
        #expect(prompt.contains("Ship on Friday."))
        #expect(prompt.contains("Ask about the budget next time."))
    }

    @Test
    func promptPointsAtTheStillMCPAccess() {
        let note = Note(template: .meeting, actions: [NoteItem(text: "Email the summary.", sourceSegmentIDs: [])])

        let prompt = AIAssistPrompt.prompt(note: note, title: "Call", recordedAt: Date(timeIntervalSince1970: 0))

        #expect(prompt.contains(MCPClientConfig.serverName))
        #expect(prompt.contains("AI Tools"))
        #expect(prompt.contains("Allow AI tools to read meetings"))
    }

    @Test
    func promptSkipsSectionsTheNoteDoesNotHave() {
        let note = Note(template: .meeting, actions: [NoteItem(text: "Email the summary.", sourceSegmentIDs: [])])

        let prompt = AIAssistPrompt.prompt(note: note, title: "Call", recordedAt: Date(timeIntervalSince1970: 0))

        #expect(prompt.contains("Email the summary."))
        #expect(!prompt.contains("Summary:"))
        #expect(!prompt.contains("Decisions:"))
        #expect(!prompt.contains("My own notes:"))
    }
}
