import CryptoKit
import Foundation
import Observation

@MainActor
protocol RecordingLibrary: AnyObject {
    func add(_ recording: Recording) throws
    func capturedAudio(forRecording id: UUID) throws -> (pcm: Data, format: AudioFormat)
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
    private(set) var recordings: [Recording] = []

    init(keyRing: LibraryKeyRing, services: LibraryServices) {
        self.keyRing = keyRing
        self.services = services
    }

    func unlock(reason: String = "Unlock your Still Library") async {
        guard state != .unlocked, state != .unlocking else { return }

        state = .unlocking
        do {
            let key = try await keyRing.unlock(reason: reason)
            let repository = services.makeRepository(key)
            recordings = try repository.load()
            self.repository = repository
            self.key = key
            try recoverInterruptedAudio(cipher: LibraryCipher(key: key))
            state = .unlocked
        } catch {
            repository = nil
            key = nil
            recordings = []
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

    func update(_ note: Note, for recording: Recording) throws {
        var updated = recording
        updated.note = note
        try write(updated)
    }

    func rename(_ recording: Recording, to title: String) throws {
        var updated = recording
        updated.title = title
        try write(updated)
    }

    func delete(_ recording: Recording) throws {
        guard let repository else { throw LibraryError.locked }

        try repository.delete(recording.id)
        try? AudioChunkStore.discard(
            AudioChunkStore.directory(forRecording: recording.id, in: services.audioRoot)
        )
        recordings.removeAll { $0.id == recording.id }
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

    func capturedAudio(forRecording id: UUID) throws -> (pcm: Data, format: AudioFormat) {
        guard let key else { throw LibraryError.locked }

        return try AudioChunkStore.mixed(
            forRecording: id,
            in: services.audioRoot,
            cipher: LibraryCipher(key: key)
        )
    }

    /// Audio left behind by a termination becomes a Recording on the next unlock.
    /// Adoption is keyed by the recording id, so repeating it creates no duplicate.
    private func recoverInterruptedAudio(cipher: LibraryCipher) throws {
        let known = Set(recordings.map(\.id))
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
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.append(recording)
            recordings.sort { $0.createdAt > $1.createdAt }
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
