import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

struct RecoveryCodeTests {
    @Test
    func generatesAReadableCodeOfFixedShape() {
        let code = RecoveryCode.generate()

        #expect(code.isWellFormed)
        #expect(code.formatted.split(separator: "-").count == RecoveryCode.groupCount)
        #expect(!code.text.contains("0"))
        #expect(!code.text.contains("O"))
    }

    @Test
    func readsBackACodeTheUserRetyped() {
        let code = RecoveryCode.generate()

        #expect(RecoveryCode(text: code.formatted.lowercased()) == code)
        #expect(RecoveryCode(text: "  \(code.formatted)  ") == code)
    }

    @Test
    func aDifferentCodeDerivesADifferentKey() {
        let salt = Data(repeating: 1, count: 32)

        #expect(RecoveryCode(text: "AAAAABBBBBCCCCCDDDDDEEEEEFFFFF").derivedKey(salt: salt)
            != RecoveryCode(text: "AAAAABBBBBCCCCCDDDDDEEEEEFFFFG").derivedKey(salt: salt))
    }
}

@MainActor
struct LibraryRecoveryTests {
    @Test
    func aWrittenDownCodeOpensTheLibraryAgain() async throws {
        let source = FakeDeviceKeySource()
        let keyRing = LibraryKeyRing(source: source)
        let master = try await keyRing.unlock(reason: "seed")

        let code = try keyRing.makeRecoveryCode(for: master)
        let restored = try keyRing.restore(using: RecoveryCode(text: code.formatted))

        #expect(restored == master)
    }

    @Test
    func aWrongCodeSaysSoInsteadOfOpeningAnything() async throws {
        let source = FakeDeviceKeySource()
        let keyRing = LibraryKeyRing(source: source)
        _ = try keyRing.makeRecoveryCode(for: try await keyRing.unlock(reason: "seed"))

        #expect(throws: LibraryKeyError.unrecoverable) {
            try keyRing.restore(using: RecoveryCode.generate())
        }
    }

    @Test
    func aLibraryWithNoRecoveryMaterialIsHonestAboutIt() {
        #expect(throws: LibraryKeyError.unrecoverable) {
            try LibraryKeyRing(source: FakeDeviceKeySource()).restore(using: RecoveryCode.generate())
        }
    }

    @Test
    func rotationLeavesTheOldKeyUnableToReadNewWrites() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory)
        let oldKey = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let recording = Recording(title: "Confidential", transcript: "board notes", duration: 30)
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: recording.id, track: .microphone, in: scratch.directory),
            cipher: LibraryCipher(key: oldKey)
        )
        try writer.append(Data(repeating: 3, count: AudioFormat.transcription.bytesPerSecond))
        try writer.finish()
        try library.add(recording)

        try await library.revokeOtherDevices()

        #expect(library.recordings.map(\.title) == ["Confidential"])
        #expect(try library.capturedAudio(forRecording: recording.id).pcm.count == AudioFormat.transcription.bytesPerSecond)

        let sealed = try library.sealForSync(library.recordings[0])

        #expect(throws: LibraryCipherError.unreadable) {
            try LibraryCipher(key: oldKey).open(sealed)
        }
    }

    private func makeLibrary(source: FakeDeviceKeySource, audioRoot: URL) async throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
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
}

@MainActor
struct RotationSafetyTests {
    @Test
    func anInterruptedRotationStillOpensTheLibrary() async throws {
        let source = FakeDeviceKeySource()
        let keyRing = LibraryKeyRing(source: source)
        let original = try await keyRing.unlock(reason: "seed")

        // The replacement is written, then the process dies before anything is
        // re-sealed and before the rotation is completed.
        let replacement = try await keyRing.beginRotation(reason: "rotate")

        #expect(replacement != original)
        #expect(source.storedPending != nil)
        #expect(source.storedWrappedKey != nil)

        // A later launch must still be able to open the Library.
        let recovered = try await LibraryKeyRing(source: source).unlock(reason: "relaunch")

        #expect(recovered == replacement)
    }

    @Test
    func abandoningARotationLeavesTheOriginalKeyInCharge() async throws {
        let source = FakeDeviceKeySource()
        let keyRing = LibraryKeyRing(source: source)
        let original = try await keyRing.unlock(reason: "seed")

        _ = try await keyRing.beginRotation(reason: "rotate")
        try keyRing.abandonRotation()

        #expect(try await LibraryKeyRing(source: source).unlock(reason: "relaunch") == original)
    }

    @Test
    func aCompletedRotationRetiresTheOldKey() async throws {
        let source = FakeDeviceKeySource()
        let keyRing = LibraryKeyRing(source: source)
        let original = try await keyRing.unlock(reason: "seed")

        let replacement = try await keyRing.beginRotation(reason: "rotate")
        try keyRing.completeRotation()

        #expect(source.storedPending == nil)
        let opened = try await LibraryKeyRing(source: source).unlock(reason: "relaunch")
        #expect(opened == replacement)
        #expect(opened != original)
    }

    @Test
    func aFailedResealKeepsEveryRecordingReadable() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let library = Library(
            keyRing: LibraryKeyRing(source: source),
            services: LibraryServices(
                audioRoot: scratch.directory,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        let recording = Recording(title: "Confidential", transcript: "board notes", duration: 30)
        try library.add(recording)

        // A track directory with a manifest but an unreadable chunk makes the
        // re-seal throw part way through.
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let directory = AudioChunkStore.trackDirectory(forRecording: recording.id, track: .microphone, in: scratch.directory)
        let writer = try AudioChunkWriter(directory: directory, cipher: LibraryCipher(key: key))
        try writer.append(Data(repeating: 2, count: AudioFormat.transcription.bytesPerSecond))
        try writer.finish()
        try Data("not ciphertext".utf8).write(to: AudioChunkStore.chunkURL(in: directory, index: 0))

        await #expect(throws: (any Error).self) {
            try await library.revokeOtherDevices()
        }

        // The Library must still open, with its text intact.
        let reopened = Library(
            keyRing: LibraryKeyRing(source: source),
            services: LibraryServices(
                audioRoot: scratch.directory,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await reopened.unlock()

        #expect(reopened.state == .unlocked)
        #expect(reopened.recordings.map(\.title) == ["Confidential"])
    }
}
