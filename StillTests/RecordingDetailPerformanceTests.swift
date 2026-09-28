import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct RecordingDetailPerformanceTests {
    @Test
    func offMainDecodeMatchesSynchronousExport() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let recording = Recording(title: "Standup", transcript: "text", duration: 3)
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory, recording: recording, seconds: 3)

        let expected = try library.audio(for: recording)
        let decoded = await library.decodedAudio(for: recording)

        #expect(!expected.isEmpty)
        #expect(decoded == expected)
    }

    @Test
    func reselectingTheSameRecordingSkipsDiskReads() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let recording = Recording(title: "Standup", transcript: "text", duration: 3)
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory, recording: recording, seconds: 3)
        let first = await library.decodedAudio(for: recording)
        #expect(!first.isEmpty)

        let trackDirectory = AudioChunkStore.trackDirectory(forRecording: recording.id, track: .microphone, in: scratch.directory)
        let chunks = try FileManager.default.contentsOfDirectory(at: trackDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == AudioChunkStore.chunkExtension }
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: chunk.path)
        }

        let second = await library.decodedAudio(for: recording)

        #expect(second == first)
    }

    @Test
    func newChunksInvalidateTheCache() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let recording = Recording(title: "Standup", transcript: "text", duration: 3)
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory, recording: recording, seconds: 2)
        let first = await library.decodedAudio(for: recording)

        let sealed = try AudioChunkStore.sealedChunk(forRecording: recording.id, track: .microphone, index: 0, in: scratch.directory)
        try AudioChunkStore.writeSealed(sealed, forRecording: recording.id, track: .microphone, part: .chunk(9), in: scratch.directory)
        let second = await library.decodedAudio(for: recording)

        #expect(second.count > first.count)
        let synced = try library.audio(for: recording)
        #expect(second == synced)
    }

    @Test
    func cachedReselectionStaysUnderBudget() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let recording = Recording(title: "Standup", transcript: "text", duration: 3)
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory, recording: recording, seconds: 3)
        _ = await library.decodedAudio(for: recording)

        let start = Date()
        let cached = await library.decodedAudio(for: recording)
        let elapsed = Date().timeIntervalSince(start)

        #expect(!cached.isEmpty)
        #expect(elapsed < 0.5)
    }

    private func makeLibrary(
        source: FakeDeviceKeySource,
        audioRoot: URL,
        recording: Recording,
        seconds: Int
    ) async throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let format = AudioFormat(sampleRate: 1_000, channels: 1, bitsPerSample: 16)
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: recording.id, track: .microphone, in: audioRoot),
            cipher: LibraryCipher(key: key),
            format: format,
            chunkSeconds: 1
        )
        try writer.append(Data(repeating: 7, count: seconds * format.bytesPerSecond))
        try writer.finish()
        let library = Library(
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
                }
            )
        )
        await library.unlock()
        try library.add(recording)
        return library
    }
}
