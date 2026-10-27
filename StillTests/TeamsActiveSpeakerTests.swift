import Foundation
import Testing
@testable import Still

struct TeamsActiveSpeakerTests {
    @Test
    func visibleParticipantsAndChatAreNotActiveSpeakers() {
        let tree = TeamsAccessibilityNode(children: [
            TeamsAccessibilityNode(identifier: "participant-tile", title: "Dana Kim"),
            TeamsAccessibilityNode(identifier: "meeting-chat", children: [
                TeamsAccessibilityNode(identifier: "participant", title: "Ben Olsen is speaking"),
            ]),
            TeamsAccessibilityNode(role: "AXStaticText", title: "Camera"),
        ])

        #expect(TeamsActiveSpeakerLabels.names(in: tree).isEmpty)
    }

    @Test
    func onlyExplicitParticipantSpeakingStateSuppliesAName() {
        let tree = TeamsAccessibilityNode(children: [
            TeamsAccessibilityNode(identifier: "participant-tile-1", description: "Dana Kim is speaking"),
            TeamsAccessibilityNode(identifier: "participant-tile-2", title: "Ben Olsen, speaking"),
            TeamsAccessibilityNode(identifier: "participant-tile-3", title: "Mina Kato"),
            TeamsAccessibilityNode(identifier: "meeting-chat", title: "Chris is speaking"),
        ])

        #expect(TeamsActiveSpeakerLabels.names(in: tree) == ["Ben Olsen", "Dana Kim"])
    }

    @Test
    func anExplicitSpeakingDescriptionNamesTheParticipantTitle() {
        let tile = TeamsAccessibilityNode(identifier: "participant-tile", title: "Dana Kim", description: "Speaking")

        #expect(TeamsActiveSpeakerLabels.names(in: tile) == ["Dana Kim"])
    }

    @Test
    func childStatusInsideParticipantTileCanIdentifyItsSpeaker() {
        let tile = TeamsAccessibilityNode(identifier: "participant-video", children: [
            TeamsAccessibilityNode(role: "AXStaticText", title: "Dana Kim (speaking)"),
        ])

        #expect(TeamsActiveSpeakerLabels.names(in: tile) == ["Dana Kim"])
    }

    @Test
    func chatMessagesCannotImpersonateSpeakingIndicators() {
        let chat = TeamsAccessibilityNode(identifier: "meeting-chat", children: [
            TeamsAccessibilityNode(role: "AXGroup", identifier: "participant-tile", description: "Dana Kim is speaking"),
        ])

        #expect(TeamsActiveSpeakerLabels.names(in: chat).isEmpty)
    }

    @Test
    func nonSpeakingAndAmbiguousLabelsRemainUnknown() {
        let tree = TeamsAccessibilityNode(identifier: "participant", children: [
            TeamsAccessibilityNode(title: "Dana Kim is not speaking"),
            TeamsAccessibilityNode(title: "You are speaking"),
            TeamsAccessibilityNode(title: "Speaking:"),
        ])

        #expect(TeamsActiveSpeakerLabels.names(in: tree).isEmpty)
    }
}

struct TeamsSpeakingLabelDiagnosticsTests {
    @Test
    func everyLabelMentioningSpeakingIsKeptForCalibration() {
        let tree = TeamsAccessibilityNode(children: [
            TeamsAccessibilityNode(role: "AXGroup", description: "Dana Kim, video on, speaking"),
            TeamsAccessibilityNode(role: "AXButton", title: "Camera"),
        ])

        #expect(TeamsActiveSpeakerLabels.speakingLabels(in: tree) == ["Dana Kim, video on, speaking"])
    }
}
