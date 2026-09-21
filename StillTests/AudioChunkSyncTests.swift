import CryptoKit
import Foundation
import Testing
@testable import Still

@MainActor
struct AudioChunkSyncTests {
    private let format = AudioFormat(sampleRate: 1_000, channels: 1, bitsPerSample: 16)

    @Test
    func uploadsEveryLocalChunkOnce() async throws {
        let scratch = try Scratch()
        let id = try write(seconds: 12, in: scratch.directory)
        let transport = FakeChunkTransport()
        let sync = AudioChunkSync(audioRoot: scratch.directory, transport: transport, freeBytes: { _ in 1 << 30 })

        await sync.sync(recordingID: id)

        #expect(sync.state == .complete)
        #expect(transport.stored.count == 4)

        await sync.sync(recordingID: id)

        #expect(sync.state == .complete)
        #expect(transport.uploads == 4)
    }

    @Test
    func resumesAnInterruptedUploadWithoutRepeatingWhatArrived() async throws {
        let scratch = try Scratch()
        let id = try write(seconds: 25, in: scratch.directory)
        let transport = FakeChunkTransport()
        transport.failUploadsAfter = 2
        let sync = AudioChunkSync(audioRoot: scratch.directory, transport: transport, freeBytes: { _ in 1 << 30 })

        await sync.sync(recordingID: id)

        #expect(sync.state == .failed(FakeChunkTransport.Interrupted().localizedDescription))
        #expect(transport.uploads == 2)

        transport.failUploadsAfter = nil
        await sync.sync(recordingID: id)

        #expect(sync.state == .complete)
        #expect(transport.uploads == 6)
    }

    @Test
    func aSecondDeviceRebuildsTheWholeRecording() async throws {
        let first = try Scratch()
        let second = try Scratch()
        let id = try write(seconds: 17, in: first.directory)
        let transport = FakeChunkTransport()
        await AudioChunkSync(audioRoot: first.directory, transport: transport, freeBytes: { _ in 1 << 30 })
            .sync(recordingID: id)

        let receiving = AudioChunkSync(audioRoot: second.directory, transport: transport, freeBytes: { _ in 1 << 30 })
        await receiving.sync(recordingID: id)

        #expect(receiving.state == .complete)
        let cipher = LibraryCipher(key: key)
        let restored = try AudioChunkStore.pcm(
            in: AudioChunkStore.trackDirectory(forRecording: id, track: .microphone, in: second.directory),
            cipher: cipher
        )
        #expect(restored == speech(seconds: 17))
    }

    @Test
    func rejectsACorruptChunkAndKeepsTheRest() async throws {
        let first = try Scratch()
        let second = try Scratch()
        let id = try write(seconds: 12, in: first.directory)
        let transport = FakeChunkTransport()
        await AudioChunkSync(audioRoot: first.directory, transport: transport, freeBytes: { _ in 1 << 30 })
            .sync(recordingID: id)
        transport.corruptsOnDownload = AudioChunkID(recordingID: id, track: .microphone, part: .chunk(1))

        let receiving = AudioChunkSync(audioRoot: second.directory, transport: transport, freeBytes: { _ in 1 << 30 })
        await receiving.sync(recordingID: id)

        let indices = AudioChunkStore.chunkIndices(forRecording: id, track: .microphone, in: second.directory)
        #expect(indices == [0, 2])
    }

    @Test
    func reportsStorageBlockedInsteadOfFillingTheDisk() async throws {
        let first = try Scratch()
        let second = try Scratch()
        let id = try write(seconds: 12, in: first.directory)
        let transport = FakeChunkTransport()
        await AudioChunkSync(audioRoot: first.directory, transport: transport, freeBytes: { _ in 1 << 30 })
            .sync(recordingID: id)

        let receiving = AudioChunkSync(audioRoot: second.directory, transport: transport, freeBytes: { _ in 1 })
        await receiving.sync(recordingID: id)

        #expect(receiving.state == .storageBlocked)
    }

    private var key: SymmetricKey {
        SymmetricKey(data: Data(repeating: 7, count: 32))
    }

    private func write(seconds: Int, in root: URL) throws -> UUID {
        let id = UUID()
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: id, track: .microphone, in: root),
            cipher: LibraryCipher(key: key),
            format: format,
            chunkSeconds: 5
        )
        try writer.append(speech(seconds: seconds))
        try writer.finish()
        return id
    }

    private func speech(seconds: Int) -> Data {
        Data((0..<(seconds * format.bytesPerSecond)).map { UInt8($0 % 251) })
    }
}

final class FakeChunkTransport: AudioChunkTransport, @unchecked Sendable {
    struct Interrupted: LocalizedError {
        var errorDescription: String? { "The transfer stopped." }
    }

    var failUploadsAfter: Int?
    var corruptsOnDownload: AudioChunkID?
    private(set) var stored: [AudioChunkID: AudioChunkPayload] = [:]
    private(set) var digests: [AudioChunkID: String] = [:]
    private(set) var uploads = 0

    func upload(_ payload: AudioChunkPayload, digest: String) async throws {
        if let failUploadsAfter, uploads >= failUploadsAfter { throw Interrupted() }

        uploads += 1
        stored[payload.id] = payload
        digests[payload.id] = digest
    }

    func inventory(forRecording id: UUID) async throws -> [AudioChunkID: String] {
        digests.filter { $0.key.recordingID == id }
    }

    func download(_ id: AudioChunkID) async throws -> AudioChunkPayload {
        guard let payload = stored[id] else { throw Interrupted() }
        guard id != corruptsOnDownload else {
            return AudioChunkPayload(id: id, sealed: Data(repeating: 0, count: payload.sealed.count))
        }
        return payload
    }
}
