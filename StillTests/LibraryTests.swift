import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct EncryptedRecordingRepositoryTests {
    @Test
    func storesContentAsCiphertext() throws {
        let context = try makeContext()
        let repository = EncryptedRecordingRepository(context: context, key: SymmetricKey(size: .bits256))
        let recording = Recording(title: "Budget review", transcript: "We agreed to delay hiring", duration: 60)

        try repository.save(recording)

        let stored = try #require(try context.fetch(FetchDescriptor<EncryptedRecording>()).first)
        let bytes = String(decoding: stored.sealedContent, as: UTF8.self)
        #expect(!bytes.contains("Budget review"))
        #expect(!bytes.contains("delay hiring"))
    }

    @Test
    func readsBackSavedRecordings() throws {
        let context = try makeContext()
        let key = SymmetricKey(size: .bits256)
        let repository = EncryptedRecordingRepository(context: context, key: key)
        let older = Recording(title: "Older", transcript: "one", createdAt: Date(timeIntervalSince1970: 0), duration: 10)
        let newer = Recording(title: "Newer", transcript: "two", createdAt: Date(timeIntervalSince1970: 100), duration: 20)

        try repository.save(older)
        try repository.save(newer)

        let loaded = try repository.load()
        #expect(loaded.map(\.title) == ["Newer", "Older"])
        #expect(loaded.map(\.transcript) == ["two", "one"])
    }

    @Test
    func refusesToReadWithAnotherKey() throws {
        let context = try makeContext()
        try EncryptedRecordingRepository(context: context, key: SymmetricKey(size: .bits256))
            .save(Recording(title: "Private", transcript: "secret", duration: 5))

        let intruder = EncryptedRecordingRepository(context: context, key: SymmetricKey(size: .bits256))

        #expect(throws: LibraryCipherError.unreadable) {
            try intruder.load()
        }
        #expect(try context.fetch(FetchDescriptor<EncryptedRecording>()).count == 1)
    }

    @Test
    func replacesContentOnRename() throws {
        let context = try makeContext()
        let repository = EncryptedRecordingRepository(context: context, key: SymmetricKey(size: .bits256))
        var recording = Recording(title: "Draft", transcript: "text", duration: 5)
        try repository.save(recording)

        recording.title = "Final"
        try repository.save(recording)

        #expect(try repository.load().map(\.title) == ["Final"])
        #expect(try context.fetch(FetchDescriptor<EncryptedRecording>()).count == 1)
    }

    @Test
    func deletesOneRecording() throws {
        let context = try makeContext()
        let repository = EncryptedRecordingRepository(context: context, key: SymmetricKey(size: .bits256))
        let kept = Recording(title: "Kept", transcript: "a", createdAt: Date(timeIntervalSince1970: 0), duration: 5)
        let removed = Recording(title: "Removed", transcript: "b", createdAt: Date(timeIntervalSince1970: 10), duration: 5)
        try repository.save(kept)
        try repository.save(removed)

        try repository.delete(removed.id)

        #expect(try repository.load().map(\.title) == ["Kept"])
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
struct LibraryUnlockTests {
    @Test
    func unlocksAndLoadsExistingRecordings() async throws {
        let source = FakeDeviceKeySource()
        let context = try makeContext()
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        try EncryptedRecordingRepository(context: context, key: key)
            .save(Recording(title: "Seeded", transcript: "text", duration: 12))

        let library = makeLibrary(source: source, context: context)
        await library.unlock()

        #expect(library.state == .unlocked)
        #expect(library.recordings.map(\.title) == ["Seeded"])
    }

    @Test
    func staysLockedWhenAuthenticationIsCancelled() async throws {
        let source = FakeDeviceKeySource()
        source.deviceKeyError = LibraryKeyError.authenticationCancelled
        let library = makeLibrary(source: source, context: try makeContext())

        await library.unlock()

        #expect(library.state == .failed(LibraryKeyError.authenticationCancelled.localizedDescription))
        #expect(library.recordings.isEmpty)
    }

    @Test
    func refusesToWriteWhileLocked() throws {
        let library = makeLibrary(source: FakeDeviceKeySource(), context: try makeContext())

        #expect(throws: LibraryError.locked) {
            try library.add(Recording(title: "Nope", transcript: "text", duration: 1))
        }
    }

    @Test
    func keepsRecordingsAfterRenameAndDelete() async throws {
        let context = try makeContext()
        let library = makeLibrary(source: FakeDeviceKeySource(), context: context)
        await library.unlock()
        let recording = Recording(title: "First", transcript: "text", duration: 30)

        try library.add(recording)
        try library.rename(recording, to: "Renamed")

        #expect(library.recordings.map(\.title) == ["Renamed"])

        try library.delete(recording)

        #expect(library.recordings.isEmpty)
    }

    private func makeLibrary(
        source: FakeDeviceKeySource,
        context: ModelContext,
        audioRoot: URL = URL.temporaryDirectory.appending(path: "still-tests/\(UUID().uuidString)")
    ) -> Library {
        Library(
            keyRing: LibraryKeyRing(source: source),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated {
                        EncryptedRecordingRepository(context: context, key: key)
                    }
                },
                makeRecorder: { _ in
                    MainActor.assumeIsolated { SpyAudioRecorder() }
                },
            makeEmbeddingEngine: { nil }
        )
        )
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
struct LibraryAudioRecoveryTests {
    @Test
    func adoptsInterruptedAudioOnceAcrossUnlocks() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let context = try makeContext()
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let format = AudioFormat(sampleRate: 1_000, channels: 1, bitsPerSample: 16)
        let id = UUID()
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: id, track: .microphone, in: scratch.directory),
            cipher: LibraryCipher(key: key),
            format: format,
            chunkSeconds: 5
        )
        try writer.append(Data(repeating: 7, count: 10 * format.bytesPerSecond))

        let library = makeLibrary(source: source, context: context, audioRoot: scratch.directory)
        await library.unlock()

        #expect(library.recordings.map(\.id) == [id])
        #expect(library.recordings.first?.duration == 10)

        let second = makeLibrary(source: source, context: context, audioRoot: scratch.directory)
        await second.unlock()

        #expect(second.recordings.map(\.id) == [id])
    }

    @Test
    func purgingAnExpiredDeletionRemovesItsAudio() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let library = makeLibrary(source: source, context: try makeContext(), audioRoot: scratch.directory)
        await library.unlock()
        let recording = Recording(title: "Spoken", transcript: "text", duration: 5)
        let directory = AudioChunkStore.directory(forRecording: recording.id, in: scratch.directory)
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: recording.id, track: .microphone, in: scratch.directory),
            cipher: LibraryCipher(key: key)
        )
        try writer.append(Data(repeating: 1, count: 32_000))
        try writer.finish()
        try library.add(recording)

        try library.delete(recording, at: Date(timeIntervalSince1970: 0))

        #expect(FileManager.default.fileExists(atPath: directory.path))

        try library.applyRetention(now: Date(timeIntervalSince1970: Retention.recoveryWindow + 1))

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeLibrary(
        source: FakeDeviceKeySource,
        context: ModelContext,
        audioRoot: URL
    ) -> Library {
        Library(
            keyRing: LibraryKeyRing(source: source),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated {
                        EncryptedRecordingRepository(context: context, key: key)
                    }
                },
                makeRecorder: { _ in
                    MainActor.assumeIsolated { SpyAudioRecorder() }
                },
            makeEmbeddingEngine: { nil }
        )
        )
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }
}
