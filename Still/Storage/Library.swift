import CryptoKit
import Foundation
import Observation

@MainActor
protocol RecordingLibrary: AnyObject {
    func add(_ recording: Recording) throws
    func capturedTracks(forRecording id: UUID) throws -> [CapturedTrack]
    func checkpointStore(forRecording id: UUID) throws -> TranscriptionCheckpointStore
    func tracks(forRecording id: UUID) -> [AudioTrack]
    var speakerNaming: SpeakerNamingContext { get }
}

@MainActor
struct LibraryServices {
    let audioRoot: URL
    let makeRepository: (SymmetricKey) -> RecordingRepository
    let makeRecorder: (SymmetricKey) -> AudioRecorder
    let makeEmbeddingEngine: () async -> EmbeddingEngine?
    var makeProjectRepository: (SymmetricKey) -> ProjectRepository = { _ in MemoryProjectRepository() }
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
    private let selectionStore: ProjectSelectionStore
    private var repository: RecordingRepository?
    private var projectRepository: ProjectRepository?
    private var key: SymmetricKey?

    private(set) var state: State = .locked
    private(set) var storedRecordings: [Recording] = []
    private(set) var semanticIndex = SemanticIndex(engine: nil)
    private(set) var storedProjects: [Project] = []
    private(set) var projectSelection: ProjectSelection
    var retentionPolicy: RetentionPolicy = .forever

    init(
        keyRing: LibraryKeyRing,
        services: LibraryServices,
        selectionStore: ProjectSelectionStore = MemoryProjectSelectionStore()
    ) {
        self.keyRing = keyRing
        self.services = services
        self.selectionStore = selectionStore
        projectSelection = selectionStore.load()
    }

    /// Only what this device shows. Every surface that reads recordings goes
    /// through this list, so a project hidden here stays hidden everywhere.
    var recordings: [Recording] {
        storedRecordings.filter { !$0.isDeleted && projectSelection.isVisible($0) }
    }

    var deletedRecordings: [Recording] {
        storedRecordings.filter { $0.isDeleted && projectSelection.isVisible($0) }
    }

    var recordingsInEveryProject: [Recording] {
        storedRecordings.filter { !$0.isDeleted }
    }

    var visibility: RecordingVisibility {
        projectSelection
    }

    var projects: [Project] {
        storedProjects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var activeProjects: [Project] {
        projects.filter { !$0.isArchived }
    }

    func project(withID id: UUID?) -> Project? {
        guard let id else { return nil }
        return storedProjects.first { $0.id == id }
    }

    /// A Mac narrowed to one project files every new recording there.
    var defaultProjectID: UUID? {
        guard let id = projectSelection.soleProjectID, project(withID: id)?.isArchived == false else { return nil }
        return id
    }

    func setProjectSelection(_ selection: ProjectSelection) {
        projectSelection = selection
        selectionStore.save(selection)
    }

    /// Audio for a recording this device hides is left in iCloud, so a
    /// restricted Mac never holds another project's voices.
    func keepsAudio(forRecording id: UUID) -> Bool {
        storedRecordings.contains { $0.id == id && projectSelection.isVisible($0) }
    }

    @discardableResult
    func createProject(named name: String, color: ProjectColor, at date: Date = .now) throws -> Project {
        let project = Project(name: name, color: color, createdAt: date)
        try writeProject(project)
        return project
    }

    func saveProject(_ project: Project) throws {
        try writeProject(project)
    }

    func assign(_ recordingIDs: some Collection<UUID>, toProject projectID: UUID?, at date: Date = .now) throws {
        for id in recordingIDs {
            guard var recording = storedRecordings.first(where: { $0.id == id }) else { continue }
            recording.assign(toProject: projectID, at: date)
            try write(recording)
        }
    }

    func unlock(reason: String = String(localized: "Unlock your Still Library")) async {
        guard state != .unlocked, state != .unlocking else { return }

        state = .unlocking
        do {
            let key = try await keyRing.unlock(reason: reason)
            let repository = services.makeRepository(key)
            storedRecordings = try repository.load()
            try loadProjects(with: key)
            self.repository = repository
            self.key = key
            try recoverInterruptedAudio(cipher: LibraryCipher(key: key))
            try applyRetention()
            state = .unlocked
            semanticIndex = SemanticIndex(engine: await services.makeEmbeddingEngine())
            semanticIndex.rebuild(storedRecordings)
        } catch {
            repository = nil
            projectRepository = nil
            key = nil
            storedRecordings = []
            storedProjects = []
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
            semanticIndex.remove(id)
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
            try loadProjects(with: key)
            self.repository = repository
            self.key = key
            state = .unlocked
            semanticIndex = SemanticIndex(engine: await services.makeEmbeddingEngine())
            semanticIndex.rebuild(storedRecordings)
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    /// Rotating re-seals everything under a key a revoked device never held, so
    /// nothing written afterwards opens with the material it kept.
    func revokeOtherDevices(reason: String = String(localized: "Rotate your Still Library key")) async throws {
        guard let oldKey = key, let repository else { throw LibraryError.locked }

        let newKey = try await keyRing.beginRotation(reason: reason)
        let oldCipher = LibraryCipher(key: oldKey)
        let newCipher = LibraryCipher(key: newKey)
        let newRepository = services.makeRepository(newKey)
        let newProjectRepository = services.makeProjectRepository(newKey)

        do {
            for recording in storedRecordings {
                for track in tracks(forRecording: recording.id) {
                    try reseal(recording.id, track: track, from: oldCipher, to: newCipher)
                }
            }

            for recording in storedRecordings {
                try newRepository.save(recording)
            }

            for project in storedProjects {
                try newProjectRepository.save(project)
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
        projectRepository = newProjectRepository
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

    func sealForSync(_ project: Project) throws -> Data {
        guard let key else { throw LibraryError.locked }

        return try LibraryCipher(key: key).seal(try JSONEncoder().encode(project))
    }

    func openProjectSyncPayload(_ sealed: Data) throws -> Project {
        guard let key else { throw LibraryError.locked }

        return try JSONDecoder().decode(Project.self, from: try LibraryCipher(key: key).open(sealed))
    }

    func applyRemote(_ remote: Project) throws {
        let local = project(withID: remote.id)
        try writeProject(local.map { Project.merge($0, remote) } ?? remote)
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
        try write(recording.renamingSpeaker(speaker, to: name))
    }

    var speakerNaming: SpeakerNamingContext {
        SpeakerNamingContext(
            profiles: VoiceProfiles.from(recordings),
            ownerName: VoiceProfiles.ownerName(in: recordings)
        )
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

    private func loadProjects(with key: SymmetricKey) throws {
        let projectRepository = services.makeProjectRepository(key)
        storedProjects = try projectRepository.load()
        self.projectRepository = projectRepository
    }

    private func writeProject(_ project: Project) throws {
        guard let projectRepository else { throw LibraryError.locked }

        try projectRepository.save(project)
        if let index = storedProjects.firstIndex(where: { $0.id == project.id }) {
            storedProjects[index] = project
        } else {
            storedProjects.append(project)
        }
    }

    private func write(_ incoming: Recording) throws {
        guard let repository else { throw LibraryError.locked }

        let recording = storedRecordings.first { $0.id == incoming.id }
            .map { incoming.keepingLatestProject(of: $0) } ?? incoming
        try repository.save(recording)
        if let index = storedRecordings.firstIndex(where: { $0.id == recording.id }) {
            storedRecordings[index] = recording
        } else {
            storedRecordings.append(recording)
            storedRecordings.sort { $0.createdAt > $1.createdAt }
        }
        semanticIndex.update(recording)
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
