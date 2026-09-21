import CryptoKit
import Foundation
import Observation

@MainActor
protocol RecordingLibrary: AnyObject {
    func add(_ recording: Recording) throws
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
    private let makeRepository: (SymmetricKey) -> RecordingRepository
    private var repository: RecordingRepository?

    private(set) var state: State = .locked
    private(set) var recordings: [Recording] = []

    init(keyRing: LibraryKeyRing, makeRepository: @escaping (SymmetricKey) -> RecordingRepository) {
        self.keyRing = keyRing
        self.makeRepository = makeRepository
    }

    func unlock(reason: String = "Unlock your Still Library") async {
        guard state != .unlocked, state != .unlocking else { return }

        state = .unlocking
        do {
            let repository = makeRepository(try await keyRing.unlock(reason: reason))
            recordings = try repository.load()
            self.repository = repository
            state = .unlocked
        } catch {
            repository = nil
            recordings = []
            state = .failed(error.localizedDescription)
        }
    }

    func add(_ recording: Recording) throws {
        try write(recording)
    }

    func rename(_ recording: Recording, to title: String) throws {
        var updated = recording
        updated.title = title
        try write(updated)
    }

    func delete(_ recording: Recording) throws {
        guard let repository else { throw LibraryError.locked }

        try repository.delete(recording.id)
        recordings.removeAll { $0.id == recording.id }
    }

    private func write(_ recording: Recording) throws {
        guard let repository else { throw LibraryError.locked }

        try repository.save(recording)
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.insert(recording, at: 0)
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
