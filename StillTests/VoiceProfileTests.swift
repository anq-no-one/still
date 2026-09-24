import Foundation
import Testing
@testable import Still

struct VoiceMatcherTests {
    private let anna = VoiceProfile(name: "Anna Kowalska", voiceprint: voice(1, 0, 0), evidence: 1)
    private let ben = VoiceProfile(name: "Ben Olsen", voiceprint: voice(0, 1, 0), evidence: 1)

    @Test
    func recognizesAVoiceCloseToANamedOne() {
        let guest = speaker(voice(0.95, 0.05, 0))

        let matches = VoiceMatcher(profiles: [anna, ben]).matches(for: [guest])

        #expect(matches[guest.id]?.name == "Anna Kowalska")
    }

    @Test
    func leavesAVoiceBeyondTheDistanceThresholdUnnamed() {
        let stranger = speaker(voice(0.5, 0.5, 0.707))

        #expect(voice(0.5, 0.5, 0.707).distance(to: anna.voiceprint) > VoiceMatcher.maximumDistance)
        #expect(VoiceMatcher(profiles: [anna, ben]).matches(for: [stranger]).isEmpty)
    }

    @Test
    func acceptsAVoiceJustInsideTheThreshold() {
        let angle = acos(1 - VoiceMatcher.maximumDistance) - 0.01
        let close = speaker(voice(cos(angle), 0, sin(angle)))

        #expect(VoiceMatcher(profiles: [anna]).matches(for: [close])[close.id] == anna)
    }

    @Test
    func refusesToChooseBetweenTwoProfilesThatSoundAlike() {
        let annaSister = VoiceProfile(name: "Maria Kowalska", voiceprint: voice(0.98, 0.2, 0), evidence: 1)
        let between = speaker(voice(0.995, 0.1, 0))

        #expect(VoiceMatcher(profiles: [anna, annaSister]).matches(for: [between]).isEmpty)
    }

    @Test
    func givesOneProfileToOnlyTheClosestOfTwoVoices() {
        let closer = speaker(voice(0.99, 0.01, 0))
        let further = speaker(voice(0.9, 0.2, 0))

        let matches = VoiceMatcher(profiles: [anna]).matches(for: [further, closer])

        #expect(matches[closer.id] == anna)
        #expect(matches[further.id] == nil)
    }

    @Test
    func aSpeakerWithoutAVoiceprintIsNeverMatched() {
        let silent = Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization)

        #expect(VoiceMatcher(profiles: [anna]).matches(for: [silent]).isEmpty)
    }

    private func speaker(_ voiceprint: Voiceprint) -> Speaker {
        Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization, voiceprint: voiceprint)
    }
}

struct VoiceProfileLearningTests {
    @Test
    func onlyNamesTheUserGaveBecomeProfiles() {
        let named = guest(voice(1, 0, 0)).named("Anna Kowalska", by: .user)
        let guessed = guest(voice(0, 1, 0)).named("Ben Olsen", by: .calendar)
        let unnamed = guest(voice(0, 0, 1))

        let profiles = VoiceProfiles.from([recording(named, guessed, unnamed)])

        #expect(profiles.map(\.name) == ["Anna Kowalska"])
    }

    @Test
    func aNameGivenInSeveralMeetingsAveragesTheVoices() throws {
        let first = recording(guest(voice(1, 0, 0)).named("Anna Kowalska", by: .user), at: 1)
        let second = recording(guest(voice(0, 1, 0)).named("anna kowalska", by: .user), at: 2)

        let profile = try #require(VoiceProfiles.from([first, second]).first)

        #expect(profile.evidence == 2)
        #expect(profile.name == "anna kowalska")
        #expect(profile.voiceprint == voice(1, 1, 0))
    }

    @Test
    func renamingASpeakerMovesItsVoiceToTheNewName() {
        let speaker = guest(voice(1, 0, 0)).named("Ana", by: .user)
        let before = recording(speaker)

        let after = before.renamingSpeaker(speaker, to: "Anna Kowalska")

        #expect(VoiceProfiles.from([before]).map(\.name) == ["Ana"])
        #expect(VoiceProfiles.from([after]).map(\.name) == ["Anna Kowalska"])
        #expect(after.speakers[0].voiceprint == speaker.voiceprint)
        #expect(after.speakers[0].id == speaker.id)
    }

    @Test
    func renamingARecognizedSpeakerTeachesTheProfile() {
        let recognized = guest(voice(0, 1, 0)).named("Anna Kowalska", by: .voiceProfile)
        let earlier = recording(guest(voice(1, 0, 0)).named("Anna Kowalska", by: .user), at: 1)
        let later = recording(recognized, at: 2)

        let confirmed = later.renamingSpeaker(recognized, to: "Anna Kowalska")

        #expect(VoiceProfiles.from([earlier, later]).first?.evidence == 1)
        #expect(VoiceProfiles.from([earlier, confirmed]).first?.evidence == 2)
    }

    @Test
    func aBlankNameIsIgnored() {
        let speaker = guest(voice(1, 0, 0))
        let before = recording(speaker)

        #expect(before.renamingSpeaker(speaker, to: "  ") == before)
    }

    @Test
    func theOwnersNameComesFromTheNewestRecordingWhereTheyNamedThemselves() {
        let old = recording(Speaker.forTrack(.microphone).named("Andrii", by: .user), at: 1)
        let new = recording(Speaker.forTrack(.microphone).named("Andrii D.", by: .user), at: 2)
        let unnamed = recording(Speaker.forTrack(.microphone), at: 3)

        #expect(VoiceProfiles.ownerName(in: [old, unnamed, new]) == "Andrii D.")
        #expect(VoiceProfiles.ownerName(in: [unnamed]) == nil)
    }

    private func guest(_ voiceprint: Voiceprint) -> Speaker {
        Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization, voiceprint: voiceprint)
    }

    private func recording(_ speakers: Speaker..., at seconds: TimeInterval = 0) -> Recording {
        Recording(
            title: "Call",
            transcript: "",
            speakers: speakers,
            createdAt: Date(timeIntervalSince1970: seconds),
            duration: 60
        )
    }
}

struct CalendarSuggestionTests {
    @Test
    func offersOnlyTheAttendeesNobodyIsNamedAfter() {
        let recording = Recording(
            title: "Call",
            transcript: "",
            speakers: [
                Speaker.forTrack(.microphone).named("Andrii D.", by: .owner),
                Speaker(name: "Anna Kowalska", origin: .system, isYou: false, nameSource: .voiceProfile),
                Speaker(name: "Speaker 2", origin: .system, isYou: false, nameSource: .diarization),
                Speaker(name: "Speaker 3", origin: .system, isYou: false, nameSource: .diarization),
            ],
            expectedParticipants: ["anna kowalska", "Ben Olsen", "Andrii D.", "Chloé Martin", "Ben Olsen"],
            duration: 60
        )

        #expect(recording.unclaimedParticipants == ["Ben Olsen", "Chloé Martin"])
    }

    @Test
    func pickingASuggestionTakesItOffTheList() {
        let guest = Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization)
        let recording = Recording(
            title: "Call",
            transcript: "",
            speakers: [guest],
            expectedParticipants: ["Ben Olsen", "Chloé Martin"],
            duration: 60
        )

        let renamed = recording.renamingSpeaker(guest, to: "Ben Olsen")

        #expect(renamed.unclaimedParticipants == ["Chloé Martin"])
        #expect(!renamed.speakers[0].isUnnamedGuest)
    }

    @Test
    func onlyUnnamedGuestsGetSuggestions() {
        #expect(Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization).isUnnamedGuest)
        #expect(Speaker.forTrack(.system).isUnnamedGuest)
        #expect(!Speaker.forTrack(.microphone).isUnnamedGuest)
        #expect(!Speaker(name: "Anna", origin: .system, isYou: false, nameSource: .calendar).isUnnamedGuest)
    }
}

struct SpeakerNamingTests {
    private let you = Speaker.forTrack(.microphone)

    @Test
    func theMicrophoneTakesTheOwnersName() {
        let named = SpeakerNaming.name([you], context: SpeakerNamingContext(ownerName: "Andrii D."))

        #expect(named.map(\.name) == ["Andrii D."])
        #expect(named[0].nameSource == .owner)
        #expect(named[0].id == you.id)
    }

    @Test
    func aRecognizedVoiceTakesItsProfileName() {
        let guest = diarized(voice(1, 0, 0))
        let profile = VoiceProfile(name: "Anna Kowalska", voiceprint: voice(1, 0, 0), evidence: 3)

        let named = SpeakerNaming.name([you, guest], context: SpeakerNamingContext(profiles: [profile]))

        #expect(named[1].name == "Anna Kowalska")
        #expect(named[1].nameSource == .voiceProfile)
    }

    @Test
    func theOnlyUnknownGuestTakesTheOnlyExpectedAttendeeLeft() {
        let anna = diarized(voice(1, 0, 0))
        let stranger = diarized(voice(0, 1, 0))
        let context = SpeakerNamingContext(
            profiles: [VoiceProfile(name: "Anna Kowalska", voiceprint: voice(1, 0, 0), evidence: 1)],
            participants: ["Anna Kowalska", "Ben Olsen", "Andrii D."],
            ownerName: "Andrii D."
        )

        let named = SpeakerNaming.name([you, anna, stranger], context: context)

        #expect(named.map(\.name) == ["Andrii D.", "Anna Kowalska", "Ben Olsen"])
        #expect(named[2].nameSource == .calendar)
    }

    @Test
    func severalUnknownGuestsKeepTheirNumbersRatherThanAGuess() {
        let guests = [diarized(voice(1, 0, 0)), diarized(voice(0, 1, 0))]
        let context = SpeakerNamingContext(participants: ["Anna Kowalska", "Ben Olsen"])

        let named = SpeakerNaming.name(guests, context: context)

        #expect(named == guests)
    }

    @Test
    func aNameTheUserGaveIsNeverReplaced() {
        let chosen = diarized(voice(1, 0, 0)).named("Anna", by: .user)
        let mine = you.named("Me", by: .user)
        let context = SpeakerNamingContext(
            profiles: [VoiceProfile(name: "Maria", voiceprint: voice(1, 0, 0), evidence: 1)],
            participants: ["Ben Olsen"],
            ownerName: "Andrii D."
        )

        #expect(SpeakerNaming.name([mine, chosen], context: context) == [mine, chosen])
    }

    private func diarized(_ voiceprint: Voiceprint) -> Speaker {
        Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization, voiceprint: voiceprint)
    }
}

private func voice(_ values: Float...) -> Voiceprint {
    Voiceprint(values)!
}
