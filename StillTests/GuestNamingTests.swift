import Foundation
import Testing
@testable import Still

struct GuestNamingTests {
    private let you = Speaker.forTrack(.microphone)
    private let phil = Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization)
    private let anna = Speaker(name: "Speaker 2", origin: .system, isYou: false, nameSource: .diarization)

    @Test
    func beingAddressedByNameTwiceNamesTheVoice() throws {
        let call = conversation([
            (you, "Hey Phil, how are you?"),
            (phil, "Good, thanks. The build is green."),
            (you, "Great. So, Phil, what's left for Friday?"),
            (phil, "Only the release notes."),
        ])

        let named = GuestNaming.name(call)

        let speaker = try #require(named.speakers.first { $0.id == phil.id })
        #expect(speaker.name == "Phil")
        #expect(speaker.nameSource == .spoken)
    }

    @Test
    func aSingleMentionOnlySuggestsTheName() throws {
        let call = conversation([
            (you, "Hey Phil, how are you?"),
            (phil, "Good, thanks. The build is green."),
        ])

        let speaker = try #require(GuestNaming.name(call).speakers.first { $0.id == phil.id })

        #expect(speaker.name == "Speaker 1")
        #expect(speaker.suggestedName == "Phil")
    }

    @Test
    func thanksGoesToTheVoiceThatJustSpoke() throws {
        let call = conversation([
            (phil, "The build is green and the release notes are done."),
            (you, "Thanks, Phil. Anna, anything from design?"),
            (anna, "The onboarding screens are ready."),
        ])

        let named = GuestNaming.name(call)

        #expect(named.speakers.first { $0.id == phil.id }?.suggestedName == "Phil")
        #expect(named.speakers.first { $0.id == anna.id }?.suggestedName == "Anna")
    }

    @Test
    func aSelfIntroductionNamesTheSpeaker() throws {
        let call = conversation([
            (anna, "Hi everyone, this is Anna from design."),
            (you, "Welcome."),
        ])

        #expect(GuestNaming.name(call).speakers.first { $0.id == anna.id }?.suggestedName == "Anna")
    }

    @Test
    func aCueAndASpokenNameThatAgreeAreApplied() throws {
        let call = conversation([
            (anna, "Hi everyone, this is Anna Lee from design."),
            (you, "Welcome."),
        ])

        let named = GuestNaming.name(call, cues: [SpeakerCue(name: "Anna Lee", start: 0, end: 3.6)])

        let speaker = try #require(named.speakers.first { $0.id == anna.id })
        #expect(speaker.name == "Anna Lee")
        #expect(speaker.nameSource == .callCue)
    }

    @Test(arguments: ["Hey Siri, set a timer.", "Thanks, guys.", "Okay Google, play music.", "Yesterday, we shipped it.", "I'm Sorry about that."])
    func wordsThatAreNotNamesAreIgnored(line: String) {
        let call = conversation([
            (you, line),
            (phil, "Sure thing."),
            (you, line),
            (phil, "Sure thing."),
        ])

        #expect(GuestNaming.name(call) == call)
    }

    @Test
    func theOwnersNameIsNeverGivenToAGuest() {
        let call = conversation([
            (you, "Hey Andrii, how are you?"),
            (phil, "Good."),
            (you, "So, Andrii, what's next?"),
            (phil, "Nothing."),
        ])

        #expect(GuestNaming.name(call, ownerName: "Andrii") == call)
    }

    @Test
    func aNameTheUserGaveIsKept() {
        var dana = phil
        dana.name = "Dana"
        dana.nameSource = .user
        let call = conversation([
            (you, "Hey Phil, how are you?"),
            (dana, "Good."),
            (you, "So, Phil, what's next?"),
            (dana, "Nothing."),
        ])

        #expect(GuestNaming.name(call) == call)
    }

    @Test
    func oneNameGoesToOneVoiceOnly() throws {
        let call = conversation([
            (you, "Hey Phil, how are you?"),
            (phil, "Good."),
            (you, "So, Phil, what's next?"),
            (phil, "Nothing."),
            (you, "Phil, can you share the doc?"),
            (anna, "I can share it instead."),
        ])

        let named = GuestNaming.name(call)

        #expect(named.speakers.first { $0.id == phil.id }?.name == "Phil")
        #expect(named.speakers.first { $0.id == anna.id }?.name == "Speaker 2")
        #expect(named.speakers.first { $0.id == anna.id }?.suggestedName == nil)
    }

    @Test
    func aSpokenFirstNameResolvesToTheFullRosterName() throws {
        let call = conversation([
            (you, "Hey Phil, how are you?"),
            (phil, "Good."),
            (you, "So, Phil, what's next?"),
            (phil, "Nothing."),
        ])

        let named = GuestNaming.name(call, roster: ["Phil Carter", "Anna Lee"])

        #expect(named.speakers.first { $0.id == phil.id }?.name == "Phil Carter")
    }

    @Test
    func conflictingNamesStayUnnamed() {
        let call = conversation([
            (you, "Hey Phil, how are you?"),
            (phil, "Good."),
            (you, "Hey Mark, are you there?"),
            (phil, "Yes."),
        ])

        let speaker = GuestNaming.name(call).speakers.first { $0.id == phil.id }

        #expect(speaker?.name == "Speaker 1")
        #expect(speaker?.suggestedName == nil)
    }

    private func conversation(_ lines: [(Speaker, String)]) -> TranscriptionResult {
        var clock: TimeInterval = 0
        let segments = lines.map { speaker, text in
            defer { clock += 4 }
            return TranscriptSegment(start: clock, end: clock + 3.5, text: text, language: "en", confidence: 0.9)
                .attributed(to: speaker)
        }
        var speakers: [Speaker] = []
        for (speaker, _) in lines where !speakers.contains(where: { $0.id == speaker.id }) {
            speakers.append(speaker)
        }
        return TranscriptionResult(segments: segments, speakers: speakers)
    }
}
