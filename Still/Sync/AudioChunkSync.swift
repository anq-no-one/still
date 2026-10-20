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
}

struct ScopeChunkSealing: Sendable {
    let local: LibraryCipher
    let scopeKey: SymmetricKey

    func outgoing(_ localSealed: Data) throws -> (payload: Data, digest: String) {
        let plaintext = try local.open(localSealed)
        return (try LibraryCipher(key: scopeKey).seal(plaintext), digest(of: plaintext))
    }

    func incoming(_ payload: Data, digest expected: String?) -> Data? {
        guard let plaintext = try? LibraryCipher(key: scopeKey).open(payload), digest(of: plaintext) == expected else {
            return nil
        }
        return try? local.seal(plaintext)
    }

    private func digest(of plaintext: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: plaintext, using: scopeKey).map { String(format: "%02x", $0) }.joined()
    }
}

protocol AudioChunkTransport: Sendable {
    func upload(_ payload: AudioChunkPayload, digest: String) async throws
    func commit(_ digests: [AudioChunkID: String], forRecording id: UUID) async throws
    func inventory(forRecording id: UUID) async throws -> [AudioChunkID: String]
    func download(_ id: AudioChunkID) async throws -> AudioChunkPayload
}

extension AudioChunkTransport {
    func commit(_ digests: [AudioChunkID: String], forRecording id: UUID) async throws {}
}

/// The digests of one recording's uploaded chunks, keyed so a chunk's address
/// survives a round trip through a record name.
struct AudioChunkIndex: Codable, Equatable, Sendable {
    private(set) var entries: [String: String] = [:]

    mutating func add(_ digests: [AudioChunkID: String]) {
        for (id, digest) in digests {
            entries[Self.key(for: id)] = digest
        }
    }

    func digests(forRecording recordingID: UUID) -> [AudioChunkID: String] {
        Dictionary(uniqueKeysWithValues: entries.compactMap { key, digest in
            Self.id(from: key, recordingID: recordingID).map { ($0, digest) }
        })
    }

    static func key(for id: AudioChunkID) -> String {
        switch id.part {
        case .manifest: "\(id.track.rawValue)/m"
        case .chunk(let index): "\(id.track.rawValue)/c\(index)"
        }
    }

    static func id(from key: String, recordingID: UUID) -> AudioChunkID? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let track = AudioTrack(rawValue: parts[0]) else { return nil }
        if parts[1] == "m" {
            return AudioChunkID(recordingID: recordingID, track: track, part: .manifest)
        }
        guard parts[1].hasPrefix("c"), let index = Int(parts[1].dropFirst()) else { return nil }
        return AudioChunkID(recordingID: recordingID, track: track, part: .chunk(index))
    }

    static func recordName(for id: AudioChunkID) -> String {
        "audio-\(id.recordingID.uuidString)-" + key(for: id).replacingOccurrences(of: "/", with: "-")
    }

    static func indexRecordName(forRecording id: UUID) -> String {
        "audio-index-\(id.uuidString)"
    }
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
    private let keepsAudio: (UUID) -> Bool
    private let sealing: (UUID) -> ScopeChunkSealing?

    private(set) var state: State = .idle

    init(
        audioRoot: URL,
        transport: AudioChunkTransport,
        freeBytes: @escaping (URL) -> Int? = ModelPackInstaller.freeBytes,
        keepsAudio: @escaping (UUID) -> Bool = { _ in true },
        sealing: @escaping (UUID) -> ScopeChunkSealing?
    ) {
        self.audioRoot = audioRoot
        self.transport = transport
        self.freeBytes = freeBytes
        self.keepsAudio = keepsAudio
        self.sealing = sealing
    }

    /// Answers whether this recording's audio is in the same place on both
    /// sides, so a caller can stop asking about it.
    @discardableResult
    func sync(recordingID: UUID) async -> Bool {
        guard let sealing = sealing(recordingID) else {
            state = .complete
            return false
        }

        do {
            let remote = try await transport.inventory(forRecording: recordingID)
            let toUpload = try localPayloads(for: recordingID).compactMap { local -> (AudioChunkPayload, String)? in
                let outgoing = try sealing.outgoing(local.sealed)
                guard remote[local.id] != outgoing.digest else { return nil }
                return (AudioChunkPayload(id: local.id, sealed: outgoing.payload), outgoing.digest)
            }
            let local = localPayloads(for: recordingID)
            let toDownload = keepsAudio(recordingID)
                ? remote.keys.filter { id in !local.contains { $0.id == id } }
                : []

            let total = toUpload.count + toDownload.count
            guard total > 0 else {
                state = .complete
                return !local.isEmpty
            }

            state = .queued(total)
            var done = 0

            var uploaded: [AudioChunkID: String] = [:]
            for (payload, digest) in toUpload {
                try await transport.upload(payload, digest: digest)
                uploaded[payload.id] = digest
                done += 1
                state = .transferring(completed: done, total: total)
                if uploaded.count >= Self.commitEvery {
                    try await transport.commit(uploaded, forRecording: recordingID)
                    uploaded = [:]
                }
            }
            try await transport.commit(uploaded, forRecording: recordingID)

            for id in toDownload.sorted(by: Self.isOrdered) {
                guard hasRoomForAnotherChunk() else {
                    state = .storageBlocked
                    return false
                }

                let payload = try await transport.download(id)
                guard let localSealed = sealing.incoming(payload.sealed, digest: remote[id]) else { continue }

                try AudioChunkStore.writeSealed(
                    localSealed,
                    forRecording: id.recordingID,
                    track: id.track,
                    part: id.part,
                    in: audioRoot
                )
                done += 1
                state = .transferring(completed: done, total: total)
            }

            state = .complete
            return false
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    static let commitEvery = 50

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

protocol AudioSyncLedger: Sendable {
    func isSettled(_ recordingID: UUID) -> Bool
    func settle(_ recordingID: UUID)
}

/// Original audio follows the text to every device, so any of them can play a
/// meeting back or hand its exact tracks to a debug bundle.
@MainActor
final class LibraryAudioSync {
    private let library: Library
    private let chunks: AudioChunkSync
    private let ledger: AudioSyncLedger

    init(library: Library, chunks: AudioChunkSync, ledger: AudioSyncLedger) {
        self.library = library
        self.chunks = chunks
        self.ledger = ledger
    }

    func run() async {
        let pending = library.storedRecordings
            .filter { !$0.isProcessing && !$0.isDeleted && !ledger.isSettled($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        for recording in pending {
            guard library.state == .unlocked else { return }
            if await chunks.sync(recordingID: recording.id) {
                ledger.settle(recording.id)
            }
        }
    }
}

struct UserDefaultsAudioSyncLedger: AudioSyncLedger, @unchecked Sendable {
    private let key = "still.sync.audioSettled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isSettled(_ recordingID: UUID) -> Bool {
        (defaults.array(forKey: key) as? [String] ?? []).contains(recordingID.uuidString)
    }

    func settle(_ recordingID: UUID) {
        var settled = defaults.array(forKey: key) as? [String] ?? []
        guard !settled.contains(recordingID.uuidString) else { return }
        settled.append(recordingID.uuidString)
        defaults.set(settled, forKey: key)
    }
}
