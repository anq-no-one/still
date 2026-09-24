import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct OwnerNameTests {
    @Test
    func theOwnersNameIsSealedAndSurvivesAnotherUnlock() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let context = try makeContext()
        let library = await makeLibrary(source: source, context: context, audioRoot: scratch.directory)

        try library.setOwnerName("  Andrii Dubovyk ")

        let sealed = try Data(contentsOf: scratch.directory.appending(path: "Library.settings"))
        #expect(!String(decoding: sealed, as: UTF8.self).contains("Andrii"))
        let reopened = await makeLibrary(source: source, context: context, audioRoot: scratch.directory)
        #expect(reopened.ownerName == "Andrii Dubovyk")
        #expect(reopened.speakerNaming.ownerName == "Andrii Dubovyk")
    }

    @Test
    func theFirstRenameOfYouSetsTheOwnersNameOnce() async throws {
        let scratch = try Scratch()
        let library = await makeLibrary(source: FakeDeviceKeySource(), context: try makeContext(), audioRoot: scratch.directory)
        let you = Speaker.forTrack(.microphone)
        let guest = Speaker.forTrack(.system)
        let recording = Recording(title: "Call", transcript: "", speakers: [you, guest], duration: 60)
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)

        editor.renameSpeaker(guest, to: "Anna Kowalska")
        #expect(library.ownerName == nil)

        editor.renameSpeaker(you, to: "Andrii Dubovyk")
        editor.renameSpeaker(you, to: "Andrii")

        #expect(library.ownerName == "Andrii Dubovyk")
        #expect(editor.recording.speakers[0].name == "Andrii")
    }

    @Test
    func deletingEveryRecordingKeepsTheOwnersName() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let context = try makeContext()
        let library = await makeLibrary(source: source, context: context, audioRoot: scratch.directory)
        let you = Speaker.forTrack(.microphone)
        let recording = Recording(title: "Call", transcript: "", speakers: [you], duration: 60)
        try library.add(recording)

        try library.renameSpeaker(you, to: "Andrii Dubovyk", in: recording)
        try library.delete(recording, at: Date(timeIntervalSince1970: 0))
        try library.applyRetention(now: Date(timeIntervalSince1970: Retention.recoveryWindow + 1))

        #expect(library.storedRecordings.isEmpty)
        let reopened = await makeLibrary(source: source, context: context, audioRoot: scratch.directory)
        #expect(reopened.ownerName == "Andrii Dubovyk")
    }

    @Test
    func aBlankNameForgetsTheOwner() async throws {
        let scratch = try Scratch()
        let library = await makeLibrary(source: FakeDeviceKeySource(), context: try makeContext(), audioRoot: scratch.directory)
        try library.setOwnerName("Andrii Dubovyk")

        try library.setOwnerName("   ")

        #expect(library.ownerName == nil)
    }

    @Test
    func rotatingTheKeyKeepsTheOwnersName() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let context = try makeContext()
        let library = await makeLibrary(source: source, context: context, audioRoot: scratch.directory)
        try library.setOwnerName("Andrii Dubovyk")

        try await library.revokeOtherDevices()

        let reopened = await makeLibrary(source: source, context: context, audioRoot: scratch.directory)
        #expect(reopened.ownerName == "Andrii Dubovyk")
    }

    @Test
    func aLockedLibraryRefusesToStoreTheName() throws {
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: URL.temporaryDirectory,
                makeRepository: { _ in MainActor.assumeIsolated { MemoryRepository() } },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )

        #expect(throws: LibraryError.locked) {
            try library.setOwnerName("Andrii Dubovyk")
        }
    }

    @Test
    func namingAVoiceRemembersNothingWithoutConsent() async throws {
        let scratch = try Scratch()
        let library = await makeLibrary(source: FakeDeviceKeySource(), context: try makeContext(), audioRoot: scratch.directory)
        let guest = Speaker(name: "Speaker 2", origin: .system, isYou: false, nameSource: .diarization, voiceprint: Voiceprint([1, 0, 0]))
        let recording = Recording(title: "Call", transcript: "", speakers: [guest], duration: 60)
        try library.add(recording)

        try library.renameSpeaker(guest, to: "Dana Kim", in: recording)
        #expect(library.speakerNaming.profiles.isEmpty)

        try library.rememberVoice(of: "Dana Kim")
        #expect(library.speakerNaming.profiles.map(\.name) == ["Dana Kim"])
        #expect(library.remembersVoice(of: "dana kim"))

        let settings = try Data(contentsOf: scratch.directory.appending(path: "Library.settings"))
        #expect(!String(decoding: settings, as: UTF8.self).contains("Dana"))

        try library.forgetVoice(of: "Dana Kim")
        #expect(library.speakerNaming.profiles.isEmpty)
    }

    private func makeLibrary(source: FakeDeviceKeySource, context: ModelContext, audioRoot: URL) async -> Library {
        let library = Library(
            keyRing: LibraryKeyRing(source: source),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        return library
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }
}

@MainActor
private final class MemoryRepository: RecordingRepository {
    func load() throws -> [Recording] { [] }
    func save(_ recording: Recording) throws {}
    func delete(_ id: UUID) throws {}
}
