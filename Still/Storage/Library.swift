import CryptoKit
import Foundation
import Observation

@MainActor
protocol RecordingLibrary: AnyObject {
    func add(_ recording: Recording) throws
    func capturedTracks(forRecording id: UUID) throws -> [CapturedTrack]
    func checkpointStore(forRecording id: UUID) throws -> TranscriptionCheckpointStore
    func tracks(forRecording id: UUID) -> [AudioTrack]
}

@MainActor
struct LibraryServices {
    let audioRoot: URL
    let makeRepository: (SymmetricKey) -> RecordingRepository
    let makeRecorder: (SymmetricKey) -> AudioRecorder
}

@MainActor
@Observable
final class Library: RecordingLibrary {
    enum State: Equatable {
        case locked
        case unlocking
        case unlocked
        case failed(String)
    }

    private let keyRing: LibraryKeyRing
    private let services: LibraryServices
    private var repository: RecordingRepository?
    private var key: SymmetricKey?

    private(set) var state: State = .locked
    private(set) var storedRecordings: [Recording] = []
    var retentionPolicy: RetentionPolicy = .forever

    init(keyRing: LibraryKeyRing, services: LibraryServices) {
        self.keyRing = keyRing
        self.services = services
    }

    var recordings: [Recording] {
        storedRecordings.filter { !$0.isDeleted }
    }

    var deletedRecordings: [Recording] {
        storedRecordings.filter(\.isDeleted)
    }

    func unlock(reason: String = "Unlock your Still Library") async {
        guard state != .unlocked, state != .unlocking else { return }

        state = .unlocking
        do {
            let key = try await keyRing.unlock(reason: reason)
            let repository = services.makeRepository(key)
            storedRecordings = try repository.load()
            self.repository = repository
            self.key = key
            try recoverInterruptedAudio(cipher: LibraryCipher(key: key))
            try applyRetention()
            state = .unlocked
        } catch {
            repository = nil
            key = nil
            storedRecordings = []
            state = .failed(error.localizedDescription)
        }
    }

    func makeRecorder() throws -> AudioRecorder {
        guard let key else { throw LibraryError.locked }

        return services.makeRecorder(key)
    }

    func add(_ recording: Recording) throws {
        try write(recording)
    }

    func save(_ recording: Recording) throws {
        try write(recording)
    }

    func rename(_ recording: Recording, to title: String) throws {
        var updated = recording
        updated.title = title
        try write(updated)
    }

    /// Deleting leaves a tombstone rather than erasing at once, so the same
    /// decision reaches other devices and the user has a window to undo it.
    func delete(_ recording: Recording, at date: Date = .now) throws {
        var deleted = recording
        deleted.deletedAt = date
        deleted.updatedAt = date
        try write(deleted)
    }

    func restore(_ recording: Recording) throws {
        var restored = recording
        restored.deletedAt = nil
        restored.updatedAt = .now
        try write(restored)
    }

    func applyRetention(now: Date = .now) throws {
        guard let repository else { throw LibraryError.locked }

        let sweep = Retention.sweep(
            recordings: storedRecordings,
            policy: retentionPolicy,
            audioDirectories: audioDirectories(),
            now: now
        )

        for id in sweep.audioToDelete + sweep.orphanAudio {
            try? AudioChunkStore.discard(AudioChunkStore.directory(forRecording: id, in: services.audioRoot))
        }

        for id in sweep.recordingsToPurge {
            try repository.delete(id)
            try? AudioChunkStore.discard(AudioChunkStore.directory(forRecording: id, in: services.audioRoot))
            storedRecordings.removeAll { $0.id == id }
        }
    }

    private func audioDirectories() -> [UUID] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: services.audioRoot,
            includingPropertiesForKeys: nil
        )) ?? []

        return contents.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    func audio(for recording: Recording) throws -> Data {
        let captured = try capturedAudio(forRecording: recording.id)
        return WAVFile.data(pcm: captured.pcm, format: captured.format)
    }

    func audio(for recording: Recording, track: AudioTrack) throws -> Data {
        guard let key else { throw LibraryError.locked }

        return try AudioChunkStore.audio(
            forRecording: recording.id,
            track: track,
            in: services.audioRoot,
            cipher: LibraryCipher(key: key)
        )
    }

    func tracks(forRecording id: UUID) -> [AudioTrack] {
        AudioChunkStore.tracks(forRecording: id, in: services.audioRoot)
    }

    func checkpointStore(forRecording id: UUID) throws -> TranscriptionCheckpointStore {
        guard let key else { throw LibraryError.locked }

        return SealedCheckpointStore(
            url: AudioChunkStore.directory(forRecording: id, in: services.audioRoot)
                .appending(path: "transcript.checkpoint"),
            cipher: LibraryCipher(key: key)
        )
    }

    func makeRecoveryCode() throws -> RecoveryCode {
        guard let key else { throw LibraryError.locked }

        return try keyRing.makeRecoveryCode(for: key)
    }

    func restore(using code: RecoveryCode) async -> Bool {
        do {
            let key = try keyRing.restore(using: code)
            let repository = services.makeRepository(key)
            storedRecordings = try repository.load()
            self.repository = repository
            self.key = key
            state = .unlocked
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    /// Rotating re-seals everything under a key a revoked device never held, so
    /// nothing written afterwards opens with the material it kept.
    func revokeOtherDevices(reason: String = "Rotate your Still Library key") async throws {
        guard let oldKey = key, let repository else { throw LibraryError.locked }

        let newKey = try await keyRing.beginRotation(reason: reason)
        let oldCipher = LibraryCipher(key: oldKey)
        let newCipher = LibraryCipher(key: newKey)
        let newRepository = services.makeRepository(newKey)

        do {
            for recording in storedRecordings {
                for track in tracks(forRecording: recording.id) {
                    try reseal(recording.id, track: track, from: oldCipher, to: newCipher)
                }
            }

            for recording in storedRecordings {
                try newRepository.save(recording)
            }
        } catch {
            // Nothing has replaced the Library key yet, so the old one still
            // opens whatever was not re-sealed.
            try? keyRing.abandonRotation()
            throw error
        }

        try keyRing.completeRotation()
        _ = repository
        self.repository = newRepository
        key = newKey
    }

    private func reseal(
        _ recordingID: UUID,
        track: AudioTrack,
        from oldCipher: LibraryCipher,
        to newCipher: LibraryCipher
    ) throws {
        let directory = AudioChunkStore.trackDirectory(
            forRecording: recordingID,
            track: track,
            in: services.audioRoot
        )

        let manifest = try AudioChunkStore.manifest(in: directory, cipher: oldCipher)
        try newCipher.seal(try JSONEncoder().encode(manifest))
            .write(to: AudioChunkStore.manifestURL(in: directory), options: .atomic)

        for index in AudioChunkStore.chunkIndices(forRecording: recordingID, track: track, in: services.audioRoot) {
            let url = AudioChunkStore.chunkURL(in: directory, index: index)
            let plaintext = try oldCipher.open(try Data(contentsOf: url))
            try newCipher.seal(plaintext).write(to: url, options: .atomic)
        }
    }

    func sealForSync(_ recording: Recording) throws -> Data {
        guard let key else { throw LibraryError.locked }

        return try LibraryCipher(key: key).seal(try JSONEncoder().encode(recording))
    }

    func openSyncPayload(_ sealed: Data) throws -> Recording {
        guard let key else { throw LibraryError.locked }

        return try JSONDecoder().decode(Recording.self, from: try LibraryCipher(key: key).open(sealed))
    }

    /// Matched against every stored Recording, tombstones included, so a copy
    /// that predates a deletion merges into it instead of arriving as new.
    func applyRemote(_ remote: Recording) throws {
        guard let local = storedRecordings.first(where: { $0.id == remote.id }) else {
            try write(remote)
            return
        }

        try write(RecordingMerge.merge(local, remote))
    }

    func archive(_ recording: Recording, tracks: [AudioTrack]) throws -> Data {
        guard let key else { throw LibraryError.locked }

        let cipher = LibraryCipher(key: key)
        let archived = try tracks.map { track -> ArchivedTrack in
            let directory = AudioChunkStore.trackDirectory(
                forRecording: recording.id,
                track: track,
                in: services.audioRoot
            )
            let manifest = try AudioChunkStore.manifest(in: directory, cipher: cipher)
            return ArchivedTrack(
                track: track,
                format: manifest.format,
                startOffset: manifest.startOffset,
                pcm: try AudioChunkStore.pcm(in: directory, cipher: cipher)
            )
        }

        return try StillArchiveCoder.seal(
            StillArchive(version: StillArchive.currentVersion, recording: recording, tracks: archived),
            with: key
        )
    }

    func importArchive(_ data: Data) throws -> Recording {
        guard let key else { throw LibraryError.locked }

        let archive = try StillArchiveCoder.open(data, with: key)
        let cipher = LibraryCipher(key: key)
        for track in archive.tracks {
            let writer = try AudioChunkWriter(
                directory: AudioChunkStore.trackDirectory(
                    forRecording: archive.recording.id,
                    track: track.track,
                    in: services.audioRoot
                ),
                cipher: cipher,
                format: track.format,
                startOffset: track.startOffset
            )
            try writer.append(track.pcm)
            try writer.finish()
        }

        try write(archive.recording)
        return archive.recording
    }

    func capturedAudio(forRecording id: UUID) throws -> (pcm: Data, format: AudioFormat) {
        guard let key else { throw LibraryError.locked }

        return try AudioChunkStore.mixed(
            forRecording: id,
            in: services.audioRoot,
            cipher: LibraryCipher(key: key)
        )
    }

    func capturedTracks(forRecording id: UUID) throws -> [CapturedTrack] {
        guard let key else { throw LibraryError.locked }

        let cipher = LibraryCipher(key: key)
        return try tracks(forRecording: id).map { track in
            let directory = AudioChunkStore.trackDirectory(forRecording: id, track: track, in: services.audioRoot)
            let manifest = try AudioChunkStore.manifest(in: directory, cipher: cipher)
            return CapturedTrack(
                track: track,
                format: manifest.format,
                startOffset: manifest.startOffset,
                pcm: try AudioChunkStore.pcm(in: directory, cipher: cipher)
            )
        }
    }

    func renameSpeaker(_ speaker: Speaker, to name: String, in recording: Recording) throws {
        guard let index = recording.speakers.firstIndex(where: { $0.id == speaker.id }) else { return }

        var updated = recording
        updated.speakers[index].name = name
        try write(updated)
    }

    /// Audio left behind by a termination becomes a Recording on the next unlock.
    /// Adoption is keyed by the recording id, so repeating it creates no duplicate.
    private func recoverInterruptedAudio(cipher: LibraryCipher) throws {
        let known = Set(storedRecordings.map(\.id))
        let interrupted = try AudioChunkStore.interruptedRecordings(in: services.audioRoot, cipher: cipher)

        for recovered in interrupted {
            try AudioChunkStore.markComplete(forRecording: recovered.id, in: services.audioRoot, cipher: cipher)
            guard !known.contains(recovered.id) else { continue }

            let createdAt = (try? recovered.directory.resourceValues(forKeys: [.creationDateKey]))?
                .creationDate ?? .now
            try write(
                Recording(
                    id: recovered.id,
                    title: RecordingTitle.from(transcript: "", date: createdAt),
                    transcript: "",
                    createdAt: createdAt,
                    duration: recovered.duration
                )
            )
        }
    }

    private func write(_ recording: Recording) throws {
        guard let repository else { throw LibraryError.locked }

        try repository.save(recording)
        if let index = storedRecordings.firstIndex(where: { $0.id == recording.id }) {
            storedRecordings[index] = recording
        } else {
            storedRecordings.append(recording)
            storedRecordings.sort { $0.createdAt > $1.createdAt }
        }
    }
}

enum LibraryError: LocalizedError {
    case locked

    var errorDescription: String? {
        switch self {
        case .locked:
            "The Library is locked."
        }
    }
}
