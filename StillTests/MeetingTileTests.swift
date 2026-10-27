import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Still

struct TeamsMeetingWindowTests {
    private func window(
        id: UInt32 = 1,
        app: String = "com.microsoft.teams2",
        title: String? = "Weekly Sync | Microsoft Teams",
        width: CGFloat = 1440,
        height: CGFloat = 900,
        onScreen: Bool = true
    ) -> MeetingWindowInfo {
        MeetingWindowInfo(
            id: id,
            appBundleID: app,
            title: title,
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            isOnScreen: onScreen
        )
    }

    @Test
    func withoutTeamsWindowsThereIsNothingToCapture() {
        #expect(TeamsMeetingWindow.resolve(from: []) == nil)
        #expect(TeamsMeetingWindow.resolve(from: [window(app: "us.zoom.xos")]) == nil)
    }

    @Test
    func theLoneMeetingWindowWins() {
        let meeting = window()

        #expect(TeamsMeetingWindow.resolve(from: [meeting]) == .window(meeting))
    }

    @Test
    func hiddenWindowsDoNotCount() {
        #expect(TeamsMeetingWindow.resolve(from: [window(onScreen: false)]) == nil)
    }

    @Test
    func twoLargeWindowsAreInconclusiveAndFallBackToTheApp() {
        let windows = [
            window(id: 1, title: "Weekly Sync | Microsoft Teams", width: 1440, height: 900),
            window(id: 2, title: "Chat with Ana | Microsoft Teams", width: 1400, height: 900),
        ]

        #expect(TeamsMeetingWindow.resolve(from: windows) == .teamsApp)
    }

    @Test
    func aSmallChatBesideALargeMeetingStillPicksTheMeeting() {
        let meeting = window(id: 1, width: 1440, height: 900)
        let chat = window(id: 2, title: "Chat", width: 400, height: 600)

        #expect(TeamsMeetingWindow.resolve(from: [chat, meeting]) == .window(meeting))
    }

    @Test
    func theOldTeamsBundleIDCountsToo() {
        let meeting = window(app: "com.microsoft.teams")

        #expect(TeamsMeetingWindow.resolve(from: [meeting]) == .window(meeting))
    }
}

struct TileCueBuilderTests {
    @Test
    func visibleNamesAreNotEvidenceOfActiveSpeech() {
        let observations = [
            TileObservation(offset: 0, names: ["Dana Kim", "Type a message"]),
            TileObservation(offset: 20, names: ["Dana Kim", "Type a message"]),
        ]

        #expect(TileCueBuilder.cues(from: observations, endingAt: 40).isEmpty)
    }

    @Test
    func anActiveNameSeenOnceIsNoise() {
        let observations = [
            TileObservation(offset: 0, names: [], activeSpeakerNames: ["Dana Kim"]),
            TileObservation(offset: 0.5, names: [], activeSpeakerNames: ["Ben Olsen"]),
            TileObservation(offset: 1, names: [], activeSpeakerNames: ["Ben Olsen"]),
        ]

        let cues = TileCueBuilder.cues(from: observations, endingAt: 1.5)

        #expect(cues.map(\.name) == ["Ben Olsen"])
    }

    @Test
    func activeSpeechEndsWhenTheNameIsNoLongerSpeaking() {
        let observations = [
            TileObservation(offset: 0, names: ["Dana Kim"], activeSpeakerNames: ["Dana Kim"]),
            TileObservation(offset: 0.5, names: ["Dana Kim"], activeSpeakerNames: ["Dana Kim"]),
            TileObservation(offset: 1, names: ["Dana Kim"]),
            TileObservation(offset: 1.5, names: ["Dana Kim"]),
        ]

        #expect(TileCueBuilder.cues(from: observations, endingAt: 20) == [
            SpeakerCue(name: "Dana Kim", start: 0, end: 1),
        ])
    }

    @Test
    func missingObservationsDoNotStretchSpeechAcrossAGap() {
        let observations = [
            TileObservation(offset: 0, names: [], activeSpeakerNames: ["Dana Kim"]),
            TileObservation(offset: 0.5, names: [], activeSpeakerNames: ["Dana Kim"]),
            TileObservation(offset: 20, names: [], activeSpeakerNames: ["Dana Kim"]),
            TileObservation(offset: 20.5, names: [], activeSpeakerNames: ["Dana Kim"]),
        ]

        #expect(TileCueBuilder.cues(from: observations, endingAt: 40) == [
            SpeakerCue(name: "Dana Kim", start: 0, end: 2),
            SpeakerCue(name: "Dana Kim", start: 20, end: 22),
        ])
    }

    @Test
    func activeSpeakerObservationsSuggestNamesThroughTheExistingMatcher() {
        let guests = Speaker.forTrack(.system)
        let transcription = TranscriptionResult(
            segments: [
                TranscriptSegment(start: 0, end: 4, text: "Welcome", language: "en", confidence: 0.9).attributed(to: guests),
            ],
            speakers: [Speaker.forTrack(.microphone), guests]
        )
        let observations = stride(from: 0.0, through: 3.5, by: 0.5).map {
            TileObservation(offset: $0, names: [], activeSpeakerNames: ["Dana Kim"])
        }
        let cues = TileCueBuilder.cues(from: observations, endingAt: 4)

        let suggested = SpeakerCueMatcher.suggest(cues, for: transcription)

        #expect(suggested.speakers.first { $0.id == guests.id }?.suggestedName == "Dana Kim")
    }

    @Test
    func framesRestEncryptedBesideTheAudioAndVanishAfterwards() throws {
        let root = try Scratch().directory
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let id = UUID()
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        try MeetingTileStore.save(png, offset: 12.5, recordingID: id, root: root, cipher: cipher)

        let stored = try FileManager.default.contentsOfDirectory(
            at: MeetingTileStore.directory(forRecording: id, in: root),
            includingPropertiesForKeys: nil
        )
        #expect(stored.count == 1)
        #expect((try? Data(contentsOf: stored[0])) != png)

        let frames = try MeetingTileStore.frames(recordingID: id, root: root, cipher: cipher)
        #expect(frames.count == 1)
        #expect(frames[0].offset == 12.5)
        #expect(frames[0].png == png)

        MeetingTileStore.discard(recordingID: id, root: root)
        #expect((try? MeetingTileStore.frames(recordingID: id, root: root, cipher: cipher))?.isEmpty ?? false)
    }

    @Test
    func unlockSweepsTileFramesLeftByAKilledRecording() throws {
        let root = try Scratch().directory
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let id = UUID()
        try MeetingTileStore.save(Data([1, 2, 3]), offset: 4, recordingID: id, root: root, cipher: cipher)
        try FileManager.default.createDirectory(
            at: root.appending(path: "not-a-recording", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        MeetingTileStore.discardLeftovers(in: root)

        #expect((try? MeetingTileStore.frames(recordingID: id, root: root, cipher: cipher))?.isEmpty ?? false)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "not-a-recording").path))
    }

    @Test
    func voiceActivityNeedsEnergyAndThenForgets() {
        let monitor = SystemVoiceActivity()
        let base = Date()

        #expect(!monitor.isActive(now: base))

        monitor.ingest(rms: 0.0001, at: base)
        #expect(!monitor.isActive(now: base))

        monitor.ingest(rms: 0.2, at: base)
        #expect(monitor.isActive(now: base))
        #expect(monitor.isActive(now: base.addingTimeInterval(SystemVoiceActivity.hangover)))
        #expect(!monitor.isActive(now: base.addingTimeInterval(SystemVoiceActivity.hangover + 1)))
    }

    @Test
    func meetingTilesDefaultOnUntilTheUserOptsOut() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let settings = UserDefaultsMeetingTileSettings(defaults: defaults)

        #expect(settings.isEnabled())

        settings.setEnabled(false)
        #expect(!UserDefaultsMeetingTileSettings(defaults: defaults).isEnabled())
    }

    @Test
    func tileCuesJoinTheDraftCuesAtFinalize() {
        let draft = RecordingFinalizer.Draft(
            id: UUID(),
            createdAt: Date(),
            duration: 30,
            cues: [SpeakerCue(name: "Ben Olsen", start: 0, end: 30)],
            tileCues: [SpeakerCue(name: "Dana Kim", start: 0, end: 30)]
        )

        #expect((draft.cues + draft.tileCues).map(\.name) == ["Ben Olsen", "Dana Kim"])
    }
}
