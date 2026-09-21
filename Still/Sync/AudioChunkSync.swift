import CryptoKit
import Foundation
import Observation

enum AudioChunkPart: Hashable, Codable, Sendable {
    case manifest
    case chunk(Int)
}

struct AudioChunkID: Hashable, Codable, Sendable {
    let recordingID: UUID
    let track: AudioTrack
    let part: AudioChunkPart
}

struct AudioChunkPayload: Equatable, Sendable {
    let id: AudioChunkID
    let sealed: Data

    var digest: String {
        SHA256.hash(data: sealed).map { String(format: "%02x", $0) }.joined()
    }
}

protocol AudioChunkTransport: Sendable {
    func upload(_ payload: AudioChunkPayload, digest: String) async throws
    func inventory(forRecording id: UUID) async throws -> [AudioChunkID: String]
    func download(_ id: AudioChunkID) async throws -> AudioChunkPayload
}

/// Moves sealed audio a chunk at a time. Every chunk is addressed by recording,
/// track, and index, so a repeat lands in the same slot, an out-of-order
/// delivery still reassembles, and an interrupted transfer picks up the pieces
/// that are missing instead of the whole Recording.
@MainActor
@Observable
final class AudioChunkSync {
    enum State: Equatable {
        case idle
        case queued(Int)
        case transferring(completed: Int, total: Int)
        case complete
        case storageBlocked
        case failed(String)
    }

    private let audioRoot: URL
    private let transport: AudioChunkTransport
    private let freeBytes: (URL) -> Int?

    private(set) var state: State = .idle

    init(
        audioRoot: URL,
        transport: AudioChunkTransport,
        freeBytes: @escaping (URL) -> Int? = ModelPackInstaller.freeBytes
    ) {
        self.audioRoot = audioRoot
        self.transport = transport
        self.freeBytes = freeBytes
    }

    func sync(recordingID: UUID) async {
        do {
            let remote = try await transport.inventory(forRecording: recordingID)
            let local = localPayloads(for: recordingID)

            let toUpload = local.filter { remote[$0.id] != $0.digest }
            let toDownload = remote.keys.filter { id in !local.contains { $0.id == id } }

            let total = toUpload.count + toDownload.count
            guard total > 0 else {
                state = .complete
                return
            }

            state = .queued(total)
            var done = 0

            for payload in toUpload {
                try await transport.upload(payload, digest: payload.digest)
                done += 1
                state = .transferring(completed: done, total: total)
            }

            for id in toDownload.sorted(by: Self.isOrdered) {
                guard hasRoomForAnotherChunk() else {
                    state = .storageBlocked
                    return
                }

                let payload = try await transport.download(id)
                guard payload.digest == remote[id] else { continue }

                try AudioChunkStore.writeSealed(
                    payload.sealed,
                    forRecording: id.recordingID,
                    track: id.track,
                    part: id.part,
                    in: audioRoot
                )
                done += 1
                state = .transferring(completed: done, total: total)
            }

            state = .complete
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func localPayloads(for recordingID: UUID) -> [AudioChunkPayload] {
        AudioChunkStore.tracks(forRecording: recordingID, in: audioRoot).flatMap { track -> [AudioChunkPayload] in
            var payloads: [AudioChunkPayload] = []

            if let manifest = try? AudioChunkStore.sealedManifest(forRecording: recordingID, track: track, in: audioRoot) {
                payloads.append(
                    AudioChunkPayload(
                        id: AudioChunkID(recordingID: recordingID, track: track, part: .manifest),
                        sealed: manifest
                    )
                )
            }

            for index in AudioChunkStore.chunkIndices(forRecording: recordingID, track: track, in: audioRoot) {
                guard let sealed = try? AudioChunkStore.sealedChunk(
                    forRecording: recordingID,
                    track: track,
                    index: index,
                    in: audioRoot
                ) else { continue }

                payloads.append(
                    AudioChunkPayload(
                        id: AudioChunkID(recordingID: recordingID, track: track, part: .chunk(index)),
                        sealed: sealed
                    )
                )
            }

            return payloads
        }
    }

    static let reservedBytes = AudioFormat.transcription.bytesPerSecond * 60

    private func hasRoomForAnotherChunk() -> Bool {
        guard let free = freeBytes(audioRoot) else { return true }
        return free > Self.reservedBytes
    }

    /// The manifest lands before the chunks it describes, and chunks arrive in
    /// index order, so a partially transferred track always reads cleanly.
    private static func isOrdered(_ first: AudioChunkID, _ second: AudioChunkID) -> Bool {
        switch (first.part, second.part) {
        case (.manifest, .manifest):
            first.track.rawValue < second.track.rawValue
        case (.manifest, .chunk):
            true
        case (.chunk, .manifest):
            false
        case (.chunk(let left), .chunk(let right)):
            first.track == second.track ? left < right : first.track.rawValue < second.track.rawValue
        }
    }
}
