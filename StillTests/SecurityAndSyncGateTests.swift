import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

/// The release gates for confidentiality and convergence. Each test is one
/// scenario the security review names, so a regression shows up as a named
/// failure rather than as a vague worry.
@MainActor
struct SecurityAndSyncGateTests {
    @Test
    func noTransportEverCarriesPlaintext() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory)
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let recording = Recording(title: "Board sync", transcript: "We agreed to delay hiring", duration: 30)
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: recording.id, track: .microphone, in: scratch.directory),
            cipher: LibraryCipher(key: key)
        )
        try writer.append(Data("raw microphone samples".utf8))
        try writer.finish()
        try library.add(recording)

        let textTransport = SpySyncTransport()
        let engine = SyncEngine(
            library: library,
            transport: textTransport,
            settings: MemorySyncSettings()
        )
        engine.enable()
        await engine.sync()

        let chunkTransport = FakeChunkTransport()
        await AudioChunkSync(audioRoot: scratch.directory, transport: chunkTransport, freeBytes: { _ in 1 << 30 })
            .sync(recordingID: recording.id)

        let onTheWire = (textTransport.pushed.flatMap { $0 }.map(\.sealedRecording)
            + chunkTransport.stored.values.map(\.sealed))
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()

        #expect(!onTheWire.contains("Board sync"))
        #expect(!onTheWire.contains("delay hiring"))
        #expect(!onTheWire.contains("raw microphone samples"))
        #expect(!onTheWire.contains(key.rawBytes.base64EncodedString()))
    }

    @Test
    func aReplayedOldChangeDoesNotUndoANewerEdit() async throws {
        let library = try await makeLibrary(source: FakeDeviceKeySource(), audioRoot: try Scratch().directory)
        let original = Recording(
            title: "Original",
            transcript: "text",
            duration: 30,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try library.add(original)
        var newer = original
        newer.title = "Renamed on this device"
        newer.updatedAt = Date(timeIntervalSince1970: 300)
        try library.save(newer)

        try library.applyRemote(original)

        let result = try #require(library.recordings.first)
        #expect(result.title.contains("Renamed on this device"))
        #expect(result.updatedAt == Date(timeIntervalSince1970: 300))
    }

    @Test
    func duplicateAndReorderedDeliveryReachTheSameResult() async throws {
        let base = Recording(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            title: "Base",
            transcript: "text",
            duration: 30,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        var fromPhone = base
        fromPhone.title = "Phone title"
        fromPhone.updatedAt = Date(timeIntervalSince1970: 200)
        var fromMac = base
        fromMac.title = "Mac title"
        fromMac.updatedAt = Date(timeIntervalSince1970: 300)

        let inOrder = try await apply([fromPhone, fromMac], to: base)
        let reversed = try await apply([fromMac, fromPhone], to: base)
        let duplicated = try await apply([fromPhone, fromMac, fromPhone, fromMac], to: base)

        #expect(inOrder.title == reversed.title)
        #expect(inOrder.title == duplicated.title)
        #expect(inOrder.title.contains("Phone title"))
        #expect(inOrder.title.contains("Mac title"))
    }

    @Test
    func threeDevicesConvergeOnTheSameRecording() async throws {
        let base = Recording(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Base",
            transcript: "text",
            note: Note(template: .meeting),
            duration: 30,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let edits = ["Phone", "Mac", "iPad"].enumerated().map { index, device -> Recording in
            var copy = base
            copy.title = device
            copy.note = Note(template: .meeting, userText: "note from \(device)")
            copy.updatedAt = Date(timeIntervalSince1970: TimeInterval(200 + index * 50))
            return copy
        }

        let one = try await apply(edits, to: base)
        let two = try await apply(edits.reversed(), to: base)

        #expect(one.title == two.title)
        #expect(one.note?.userText == two.note?.userText)
        for device in ["Phone", "Mac", "iPad"] {
            #expect(one.title.contains(device))
            #expect(one.note?.userText.contains("note from \(device)") == true)
        }
    }

    @Test
    func aRevokedDeviceCannotReadAnythingWrittenAfterwards() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory)
        let revokedKey = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        try library.add(Recording(title: "Before", transcript: "text", duration: 30))

        try await library.revokeOtherDevices()
        try library.add(Recording(title: "After", transcript: "new secret", duration: 30))

        for recording in library.recordings {
            let sealed = try library.sealForSync(recording)
            #expect(throws: LibraryCipherError.unreadable) {
                try LibraryCipher(key: revokedKey).open(sealed)
            }
        }
    }

    @Test
    func aDeletionIsNotResurrectedByAnOlderCopy() async throws {
        let library = try await makeLibrary(source: FakeDeviceKeySource(), audioRoot: try Scratch().directory)
        let recording = Recording(
            title: "Shared",
            transcript: "text",
            duration: 30,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try library.add(recording)
        try library.delete(recording, at: Date(timeIntervalSince1970: 200))

        try library.applyRemote(recording)

        #expect(library.recordings.isEmpty)
        #expect(library.deletedRecordings.count == 1)
    }

    @Test
    func purgedContentLeavesNothingReadableBehind() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory)
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let recording = Recording(title: "Temporary", transcript: "text", duration: 30)
        let directory = AudioChunkStore.trackDirectory(
            forRecording: recording.id,
            track: .microphone,
            in: scratch.directory
        )
        let writer = try AudioChunkWriter(directory: directory, cipher: LibraryCipher(key: key))
        try writer.append(Data(repeating: 5, count: 32_000))
        try writer.finish()
        try library.add(recording)
        try library.delete(recording, at: Date(timeIntervalSince1970: 0))

        try library.applyRetention(now: Date(timeIntervalSince1970: Retention.recoveryWindow + 1))

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(library.recordings.isEmpty)
        #expect(library.deletedRecordings.isEmpty)
    }

    @Test
    func anInterruptedAudioTransferLeavesNoHalfWrittenChunk() throws {
        let scratch = try Scratch()
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let id = UUID()
        let directory = AudioChunkStore.trackDirectory(forRecording: id, track: .microphone, in: scratch.directory)
        let writer = try AudioChunkWriter(directory: directory, cipher: cipher, chunkSeconds: 1)
        try writer.append(Data(repeating: 9, count: AudioFormat.transcription.bytesPerSecond * 3))

        let truncated = AudioChunkStore.chunkURL(in: directory, index: 2)
        try Data(try Data(contentsOf: truncated).dropLast(16)).write(to: truncated)

        let readable = try AudioChunkStore.pcm(in: directory, cipher: cipher)

        #expect(readable.count == AudioFormat.transcription.bytesPerSecond * 2)
        #expect(readable.allSatisfy { $0 == 9 })
    }

    private func apply(_ remotes: [Recording], to base: Recording) async throws -> Recording {
        let library = try await makeLibrary(source: FakeDeviceKeySource(), audioRoot: try Scratch().directory)
        try library.add(base)
        for remote in remotes {
            try library.applyRemote(remote)
        }
        return try #require(library.recordings.first)
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
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } },
            makeEmbeddingEngine: { nil }
        )
        )
        await library.unlock()
        return library
    }
}
