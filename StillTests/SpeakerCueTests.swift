import Foundation
import SwiftData
import Testing
@testable import Still

struct SpeakerCueMatcherTests {
    private let you = Speaker.forTrack(.microphone)
    private let guests = Speaker.forTrack(.system)

    @Test
    func withoutCuesNothingChanges() {
        let transcription = call(guests: [(0, 10)])

        #expect(SpeakerCueMatcher.suggest([], for: transcription) == transcription)
    }

    @Test
    func aCueDuringAGroupsSpeechSuggestsItsName() throws {
        let transcription = call(guests: [(0, 10)])

        let suggested = SpeakerCueMatcher.suggest([SpeakerCue(name: "Dana Kim", start: 1, end: 8)], for: transcription)

        let speaker = try #require(suggested.speakers.first { $0.id == guests.id })
        #expect(speaker.suggestedName == "Dana Kim")
        #expect(speaker.name == guests.name)
        #expect(speaker.nameSource == .track)
        #expect(suggested.segments == transcription.segments)
    }

    @Test
    func conflictingCuesStayUncertain() {
        let transcription = call(guests: [(0, 10)])
        let cues = [
            SpeakerCue(name: "Dana Kim", start: 0, end: 5),
            SpeakerCue(name: "Ben Olsen", start: 5, end: 10),
        ]

        let suggested = SpeakerCueMatcher.suggest(cues, for: transcription)

        #expect(suggested.speakers.allSatisfy { $0.suggestedName == nil })
    }

    @Test
    func aCueOutsideSpeechSuggestsNothing() {
        let transcription = call(guests: [(0, 10)])

        let suggested = SpeakerCueMatcher.suggest([SpeakerCue(name: "Dana Kim", start: 12, end: 30)], for: transcription)

        #expect(suggested == transcription)
    }

    @Test
    func aBriefOverlapIsNotEnough() {
        let transcription = call(guests: [(0, 10)])

        let suggested = SpeakerCueMatcher.suggest([SpeakerCue(name: "Dana Kim", start: 9, end: 20)], for: transcription)

        #expect(suggested == transcription)
    }

    @Test
    func aConfirmedNameIsNeverSuggestedAgain() {
        let named = Speaker(name: "Dana Kim", origin: .system, isYou: false, nameSource: .user)
        var transcription = call(guests: [(0, 10)])
        transcription.speakers.append(named)

        let suggested = SpeakerCueMatcher.suggest([SpeakerCue(name: "dana kim", start: 0, end: 10)], for: transcription)

        #expect(suggested == transcription)
    }

    @Test
    func theOwnersNameIsNeverSuggestedForAGuest() {
        let transcription = call(guests: [(0, 10)])

        let suggested = SpeakerCueMatcher.suggest(
            [SpeakerCue(name: "Andrii D.", start: 0, end: 10)],
            for: transcription,
            ownerName: "Andrii D."
        )

        #expect(suggested == transcription)
    }

    @Test
    func aNameHeardMostlyFromTheMicrophoneIsNotAGuest() {
        let transcription = call(you: [(0, 20)], guests: [(18, 22)])

        let suggested = SpeakerCueMatcher.suggest([SpeakerCue(name: "Andrii", start: 0, end: 21)], for: transcription)

        #expect(suggested.speakers.allSatisfy { $0.suggestedName == nil })
    }

    @Test
    func separatedGroupsEachGetTheirOwnName() {
        let first = Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization)
        let second = Speaker(name: "Speaker 2", origin: .system, isYou: false, nameSource: .diarization)
        let transcription = TranscriptionResult(
            segments: [segment(0, 6, by: first), segment(6, 12, by: second), segment(12, 15, by: first)],
            speakers: [first, second]
        )
        let cues = [
            SpeakerCue(name: "Dana Kim", start: 0.4, end: 6.2),
            SpeakerCue(name: "Ben Olsen", start: 6.2, end: 12.3),
            SpeakerCue(name: "Dana Kim", start: 12.3, end: 15),
        ]

        let suggested = SpeakerCueMatcher.suggest(cues, for: transcription)

        #expect(suggested.speakers.map(\.suggestedName) == ["Dana Kim", "Ben Olsen"])
    }

    @Test
    func oneNameSpreadOverTwoGroupsSuggestsNeither() {
        let first = Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization)
        let second = Speaker(name: "Speaker 2", origin: .system, isYou: false, nameSource: .diarization)
        let transcription = TranscriptionResult(
            segments: [segment(0, 5, by: first), segment(5, 10, by: second)],
            speakers: [first, second]
        )

        let suggested = SpeakerCueMatcher.suggest([SpeakerCue(name: "Dana Kim", start: 0, end: 10)], for: transcription)

        #expect(suggested.speakers.allSatisfy { $0.suggestedName == nil })
    }

    private func call(you mine: [(TimeInterval, TimeInterval)] = [], guests theirs: [(TimeInterval, TimeInterval)]) -> TranscriptionResult {
        let segments = mine.map { segment($0.0, $0.1, by: you) } + theirs.map { segment($0.0, $0.1, by: guests) }
        return TranscriptionResult(segments: segments.sorted { $0.start < $1.start }, speakers: [you, guests])
    }

    private func segment(_ start: TimeInterval, _ end: TimeInterval, by speaker: Speaker) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: "words", language: "en", confidence: 0.9)
            .attributed(to: speaker)
    }
}

struct SpeakerCueLogTests {
    @Test
    func turnsStartsAndEndsIntoCues() {
        var log = SpeakerCueLog()
        log.began("Dana Kim", at: 2)
        log.began("Dana Kim", at: 3)
        log.ended("Ben Olsen", at: 4)
        log.ended("Dana Kim", at: 5)
        log.began("Ben Olsen", at: 6)

        #expect(log.cues(closingAt: 9) == [
            SpeakerCue(name: "Dana Kim", start: 2, end: 5),
            SpeakerCue(name: "Ben Olsen", start: 6, end: 9),
        ])
    }
}

struct SpeakerSuggestionStorageTests {
    @Test
    func aSpeakerSavedBeforeSuggestionsExistedStillDecodes() throws {
        let stored = Data(#"{"id":"8C1E7F4B-6C35-4E0A-9E3C-4A1B2C3D4E5F","name":"Other participants","origin":"system","isYou":false,"nameSource":"track"}"#.utf8)

        let speaker = try JSONDecoder().decode(Speaker.self, from: stored)

        #expect(speaker.suggestedName == nil)
        #expect(speaker.name == "Other participants")
    }

    @Test
    func aSuggestionSurvivesEncoding() throws {
        let speaker = Speaker.forTrack(.system).suggesting("Dana Kim")

        let decoded = try JSONDecoder().decode(Speaker.self, from: JSONEncoder().encode(speaker))

        #expect(decoded == speaker)
    }
}

@MainActor
struct SpeakerSuggestionEditingTests {
    @Test
    func confirmingASuggestionNamesTheSpeakerWithoutAVoiceProfile() async throws {
        let (library, editor, guest) = try await edit()

        editor.confirmSuggestedName(of: guest)
        editor.saveNow()

        let saved = try #require(library.recordings.first?.speakers.first)
        #expect(saved.name == "Dana Kim")
        #expect(saved.nameSource == .callCue)
        #expect(saved.suggestedName == nil)
        #expect(!saved.isUnnamedGuest)
        #expect(VoiceProfiles.from(library.recordings).isEmpty)
    }

    @Test
    func rejectingASuggestionKeepsTheName() async throws {
        let (library, editor, guest) = try await edit()

        editor.rejectSuggestedName(of: guest)
        editor.saveNow()

        let saved = try #require(library.recordings.first?.speakers.first)
        #expect(saved.name == guest.name)
        #expect(saved.nameSource == .track)
        #expect(saved.suggestedName == nil)
    }

    @Test
    func correctingASuggestionUsesTheTypedName() async throws {
        let (library, editor, guest) = try await edit()

        editor.renameSpeaker(guest, to: "Dana Kimball")
        editor.saveNow()

        let saved = try #require(library.recordings.first?.speakers.first)
        #expect(saved.name == "Dana Kimball")
        #expect(saved.nameSource == .user)
        #expect(saved.suggestedName == nil)
    }

    private func edit() async throws -> (Library, RecordingEditor, Speaker) {
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
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } },
                makeEmbeddingEngine: { nil }
            )
        )
        await library.unlock()

        let guest = Speaker(
            name: "Other participants",
            origin: .system,
            isYou: false,
            nameSource: .track,
            voiceprint: Voiceprint([1, 0, 0]),
            suggestedName: "Dana Kim"
        )
        let segments = words("Hello everyone .").map { $0.attributed(to: guest) }
        let recording = Recording(
            title: "Call",
            transcript: segments.plainText,
            segments: segments,
            speakers: [guest],
            duration: 60
        )
        try library.add(recording)
        return (library, RecordingEditor(recording: recording, library: library), guest)
    }
}

struct SpeakerSignalTests {
    @Test
    func aSpeakerMessageCarriesACleanName() throws {
        let message = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"speakerStarted","speaker":"  Dana\u0007 \n Kim​ "}"#.utf8)

        let event = try #require(BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: nil))

        #expect(event.phase == .speakerStarted)
        #expect(event.speaker == "Dana Kim")
        #expect(BrowserMeetingSignal.event(fromPayload: BrowserMeetingSignal.payload(for: event)) == event)
    }

    @Test(arguments: [
        #"{"host":"meet.google.com","meetingID":"m","phase":"speakerStarted"}"#,
        #"{"host":"meet.google.com","meetingID":"m","phase":"speakerEnded","speaker":"\u0000\u0007 "}"#,
        #"{"host":"meet.google.com","meetingID":"m","phase":"speakerStarted","speaker":42}"#,
    ])
    func aSpeakerMessageWithoutANameIsRefused(_ message: String) {
        #expect(BrowserMeetingSignal.event(fromExtensionMessage: Data(message.utf8), browserBundleID: nil) == nil)
    }

    @Test
    func anOversizedSpeakerNameIsRefused() {
        let name = String(repeating: "a", count: BrowserMeetingSignal.maximumSpeakerLength + 1)
        let message = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"speakerStarted","speaker":"\#(name)"}"#.utf8)

        #expect(BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: nil) == nil)
    }

    @Test
    func aMeetingBoundaryDropsAnySpeaker() throws {
        let message = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"started","speaker":"Dana Kim"}"#.utf8)

        let event = try #require(BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: nil))

        #expect(event.speaker == nil)
    }
}

@MainActor
struct SpeakerCueWorkflowTests {
    @Test
    func cuesAreTimedFromTheRecordingStart() async throws {
        let library = SpyRecordingLibrary()
        library.capturedTrack = .system
        let clock = StubClock(start: Date(timeIntervalSince1970: 500))
        let workflow = RecordingWorkflow(
            session: FakeTranscriptionSession(),
            finalTranscription: FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600),
            recorder: SpyAudioRecorder(),
            library: library,
            showsLiveDraft: false,
            now: clock.now
        )

        workflow.speakerStarted("Ben Olsen")
        await workflow.start()
        clock.advance(by: 1)
        workflow.speakerStarted("Dana Kim")
        clock.advance(by: 3)
        workflow.speakerEnded("Dana Kim")
        clock.advance(by: 6)
        await workflow.save()

        let speaker = try #require(library.recordings.first?.speakers.first)
        #expect(speaker.suggestedName == "Dana Kim")
        #expect(speaker.name == Speaker.forTrack(.system).name)
    }

    @Test
    func aRecordingWithoutCuesHasNoSuggestions() async throws {
        let library = SpyRecordingLibrary()
        library.capturedTrack = .system
        let workflow = RecordingWorkflow(
            session: FakeTranscriptionSession(),
            finalTranscription: FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600),
            recorder: SpyAudioRecorder(),
            library: library,
            showsLiveDraft: false
        )

        await workflow.start()
        await workflow.save()

        #expect(library.recordings.first?.speakers.allSatisfy { $0.suggestedName == nil } == true)
    }
}

struct SpeakerDecodingTests {
    @Test
    func aNameSourceFromANewerVersionStillOpensTheRecording() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Dana","isYou":false,"nameSource":"somethingNew"}"#

        let speaker = try JSONDecoder().decode(Speaker.self, from: Data(json.utf8))

        #expect(speaker.name == "Dana")
        #expect(speaker.nameSource == nil)
    }
}
