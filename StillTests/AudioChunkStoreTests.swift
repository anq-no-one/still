import CryptoKit
import Foundation
import Testing
@testable import Still

struct AudioChunkStoreTests {
    private let format = AudioFormat(sampleRate: 1_000, channels: 1, bitsPerSample: 16)
    private let chunkSeconds: TimeInterval = 5

    @Test
    func writesChunksAsCiphertext() throws {
        let scratch = try Scratch()
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let writer = try makeWriter(in: scratch.directory, cipher: cipher)

        try writer.append(speech(seconds: 5))
        try writer.finish()

        let chunk = try Data(contentsOf: AudioChunkStore.chunkURL(in: scratch.directory, index: 0))
        #expect(chunk != speech(seconds: 5))
        #expect(try cipher.open(chunk) == speech(seconds: 5))
    }

    @Test
    func replaysChunksAsOneContinuousStream() throws {
        let scratch = try Scratch()
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let writer = try makeWriter(in: scratch.directory, cipher: cipher)
        let spoken = speech(seconds: 17)

        try writer.append(spoken.prefix(4_000))
        try writer.append(spoken.dropFirst(4_000))
        try writer.finish()

        #expect(try AudioChunkStore.pcm(in: scratch.directory, cipher: cipher) == spoken)

        let wav = try AudioChunkStore.audio(in: scratch.directory, cipher: cipher)
        #expect(wav.count == spoken.count + 44)
        #expect(wav.suffix(spoken.count) == spoken)
    }

    @Test
    func aKilledWriterLosesAtMostOneChunk() throws {
        let scratch = try Scratch()
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let writer = try makeWriter(in: scratch.directory, cipher: cipher)
        let spoken = speech(seconds: 32)

        try writer.append(spoken)
        // The process dies here: finish() never runs and the tail stays in memory.

        let recovered = try AudioChunkStore.pcm(in: scratch.directory, cipher: cipher)
        let lost = format.duration(ofBytes: spoken.count - recovered.count)
        #expect(lost <= chunkSeconds)
        #expect(recovered == spoken.prefix(recovered.count))
    }

    @Test
    func recoveryListsUnfinishedAudioOnceAndThenCompletesIt() throws {
        let scratch = try Scratch()
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let id = UUID()
        let directory = AudioChunkStore.directory(forRecording: id, in: scratch.directory)
        let writer = try makeWriter(in: directory, cipher: cipher)
        try writer.append(speech(seconds: 12))

        let interrupted = try AudioChunkStore.interruptedRecordings(in: scratch.directory, cipher: cipher)

        #expect(interrupted.map(\.id) == [id])
        #expect(interrupted.first?.duration == 10)

        try AudioChunkStore.markComplete(directory, cipher: cipher)

        #expect(try AudioChunkStore.interruptedRecordings(in: scratch.directory, cipher: cipher).isEmpty)
    }

    @Test
    func aTruncatedTailKeepsEarlierAudio() throws {
        let scratch = try Scratch()
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let writer = try makeWriter(in: scratch.directory, cipher: cipher)
        try writer.append(speech(seconds: 15))
        try writer.finish()

        let tail = AudioChunkStore.chunkURL(in: scratch.directory, index: 2)
        try Data(try Data(contentsOf: tail).dropLast(8)).write(to: tail)

        #expect(try AudioChunkStore.pcm(in: scratch.directory, cipher: cipher) == speech(seconds: 10))
    }

    @Test
    func finishedAudioIsNotOfferedForRecovery() throws {
        let scratch = try Scratch()
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let directory = AudioChunkStore.directory(forRecording: UUID(), in: scratch.directory)
        let writer = try makeWriter(in: directory, cipher: cipher)
        try writer.append(speech(seconds: 6))
        try writer.finish()

        #expect(try AudioChunkStore.interruptedRecordings(in: scratch.directory, cipher: cipher).isEmpty)
    }

    private func makeWriter(in directory: URL, cipher: LibraryCipher) throws -> AudioChunkWriter {
        try AudioChunkWriter(directory: directory, cipher: cipher, format: format, chunkSeconds: chunkSeconds)
    }

    private func speech(seconds: Int) -> Data {
        Data((0..<(seconds * format.bytesPerSecond)).map { UInt8($0 % 251) })
    }
}

final class Scratch {
    let directory: URL

    init() throws {
        directory = URL.temporaryDirectory.appending(path: "still-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
