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

        let wav = WAVFile.data(
            pcm: try AudioChunkStore.pcm(in: scratch.directory, cipher: cipher),
            format: format
        )
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
        let writer = try makeWriter(
            in: AudioChunkStore.trackDirectory(forRecording: id, track: .microphone, in: scratch.directory),
            cipher: cipher
        )
        try writer.append(speech(seconds: 12))

        let interrupted = try AudioChunkStore.interruptedRecordings(in: scratch.directory, cipher: cipher)

        #expect(interrupted.map(\.id) == [id])
        #expect(interrupted.first?.duration == 10)

        try AudioChunkStore.markComplete(forRecording: id, in: scratch.directory, cipher: cipher)

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
        let directory = AudioChunkStore.trackDirectory(forRecording: UUID(), track: .microphone, in: scratch.directory)
        let writer = try makeWriter(in: directory, cipher: cipher)
        try writer.append(speech(seconds: 6))
        try writer.finish()

        #expect(try AudioChunkStore.interruptedRecordings(in: scratch.directory, cipher: cipher).isEmpty)
    }

    private func makeWriter(
        in directory: URL,
        cipher: LibraryCipher,
        startOffset: TimeInterval = 0
    ) throws -> AudioChunkWriter {
        try AudioChunkWriter(
            directory: directory,
            cipher: cipher,
            format: format,
            chunkSeconds: chunkSeconds,
            startOffset: startOffset
        )
    }

    @Test
    func keepsTracksSeparateAndMixesThemOnOneTimeline() throws {
        let scratch = try Scratch()
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let id = UUID()
        let microphone = try makeWriter(
            in: AudioChunkStore.trackDirectory(forRecording: id, track: .microphone, in: scratch.directory),
            cipher: cipher
        )
        let system = try makeWriter(
            in: AudioChunkStore.trackDirectory(forRecording: id, track: .system, in: scratch.directory),
            cipher: cipher,
            startOffset: 5
        )
        try microphone.append(tone(value: 100, seconds: 10))
        try microphone.finish()
        try system.append(tone(value: 30, seconds: 10))
        try system.finish()

        #expect(AudioChunkStore.tracks(forRecording: id, in: scratch.directory) == [.microphone, .system])

        let micOnly = try AudioChunkStore.pcm(
            in: AudioChunkStore.trackDirectory(forRecording: id, track: .microphone, in: scratch.directory),
            cipher: cipher
        )
        #expect(micOnly == tone(value: 100, seconds: 10))

        let mixed = try AudioChunkStore.mixed(forRecording: id, in: scratch.directory, cipher: cipher)
        let samples = mixed.pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }

        #expect(samples.count == 15 * format.sampleRate)
        #expect(samples[0] == 100)
        #expect(samples[7 * format.sampleRate] == 130)
        #expect(samples[12 * format.sampleRate] == 30)
    }

    @Test
    func clampsALoudMixInsteadOfWrappingIt() throws {
        let scratch = try Scratch()
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let id = UUID()
        for track in AudioTrack.allCases {
            let writer = try makeWriter(
                in: AudioChunkStore.trackDirectory(forRecording: id, track: track, in: scratch.directory),
                cipher: cipher
            )
            try writer.append(tone(value: 30_000, seconds: 5))
            try writer.finish()
        }

        let mixed = try AudioChunkStore.mixed(forRecording: id, in: scratch.directory, cipher: cipher)
        let samples = mixed.pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }

        #expect(samples.allSatisfy { $0 == Int16.max })
    }

    private func tone(value: Int16, seconds: Int) -> Data {
        let samples = [Int16](repeating: value, count: seconds * format.sampleRate)
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
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

struct AudioChunkWriterFailureTests {
    private let format = AudioFormat(sampleRate: 1_000, channels: 1, bitsPerSample: 16)

    @Test
    func aWriterStartsWithNoFailure() throws {
        let scratch = try Scratch()
        let writer = try AudioChunkWriter(
            directory: scratch.directory.appending(path: "track"),
            cipher: LibraryCipher(key: SymmetricKey(size: .bits256)),
            format: format,
            chunkSeconds: 1
        )

        #expect(writer.failure == nil)
    }

    @Test
    func aFailedWriteIsRememberedSoCaptureCanStopAndSayWhy() throws {
        let scratch = try Scratch()
        let directory = scratch.directory.appending(path: "track")
        let writer = try AudioChunkWriter(
            directory: directory,
            cipher: LibraryCipher(key: SymmetricKey(size: .bits256)),
            format: format,
            chunkSeconds: 1
        )
        try writer.append(Data(repeating: 1, count: format.bytesPerSecond))

        #expect(writer.failure == nil)

        // The directory disappearing stands in for a disk that can no longer
        // take the next chunk.
        try FileManager.default.removeItem(at: directory)

        #expect(throws: (any Error).self) {
            try writer.append(Data(repeating: 1, count: format.bytesPerSecond))
        }
        #expect(writer.failure != nil)
    }
}
