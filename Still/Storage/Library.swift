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
    func vocabulary(forProject id: UUID?) -> ProjectVocabulary
}

@MainActor
struct LibraryServices {
    let audioRoot: URL
    let settingsFile: URL
    let keysFile: URL
    let makeRepository: (SymmetricKey) -> RecordingRepository
    let makeRecorder: (SymmetricKey) -> AudioRecorder
    let makeEmbeddingEngine: () async -> EmbeddingEngine?
    let makeProjectRepository: (SymmetricKey) -> ProjectRepository
    let makeVocabularyRepository: (SymmetricKey) -> ProjectVocabularyRepository
    let availableCapacity: (URL) -> Int64?

    init(
        audioRoot: URL,
        settingsFile: URL? = nil,
        keysFile: URL? = nil,
        makeRepository: @escaping (SymmetricKey) -> RecordingRepository,
        makeRecorder: @escaping (SymmetricKey) -> AudioRecorder,
        makeEmbeddingEngine: @escaping () async -> EmbeddingEngine? = { nil },
        makeProjectRepository: @escaping (SymmetricKey) -> ProjectRepository = { _ in MemoryProjectRepository() },
        makeVocabularyRepository: @escaping (SymmetricKey) -> ProjectVocabularyRepository = { _ in MemoryProjectVocabularyRepository() },
        availableCapacity: @escaping (URL) -> Int64? = StorageCapacity.available(at:)
    ) {
        self.audioRoot = audioRoot
        self.settingsFile = settingsFile ?? audioRoot.appending(path: "Library.settings")
        self.keysFile = keysFile ?? audioRoot.appending(path: "Library.keys")
        self.makeRepository = makeRepository
        self.makeRecorder = makeRecorder
        self.makeEmbeddingEngine = makeEmbeddingEngine
        self.makeProjectRepository = makeProjectRepository
        self.makeVocabularyRepository = makeVocabularyRepository
        self.availableCapacity = availableCapacity
    }
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
    private var vocabularyRepository: ProjectVocabularyRepository?
    private var key: SymmetricKey?
    private var accountKeys: AccountKeys?
    private var dashboardCache: (key: String, dashboard: Dashboard?) = ("", nil)

    private(set) var state: State = .locked
    private(set) var storedRecordings: [Recording] = []
    private(set) var semanticIndex = SemanticIndex(engine: nil)
    private(set) var storedProjects: [Project] = []
    private(set) var storedVocabularies: [ProjectVocabulary] = []
    private(set) var projectSelection: ProjectSelection
    private(set) var settings = LibrarySettings()
    var retentionPolicy: RetentionPolicy = .forever
    let journal: DiagnosticJournal?

    init(
        keyRing: LibraryKeyRing,
        services: LibraryServices,
        selectionStore: ProjectSelectionStore = MemoryProjectSelectionStore(),
        journal: DiagnosticJournal? = nil
    ) {
        self.keyRing = keyRing
        self.services = services
        self.selectionStore = selectionStore
        self.journal = journal
        projectSelection = selectionStore.load()
    }

    /// Only what this device shows. Every surface that reads recordings goes
    /// through this list, so a project hidden here stays hidden everywhere.
    var recordings: [Recording] {
        storedRecordings.filter { !$0.isDeleted && !$0.isArchived && projectSelection.isVisible($0) }
    }

    var archivedRecordings: [Recording] {
        storedRecordings.filter { $0.isArchived && !$0.isDeleted && projectSelection.isVisible($0) }
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
        storedRecordings.contains { $0.id == id && projectSelection.isVisible($0) && holds($0.projectScope) }
    }

    func audioSealing(forRecording id: UUID) -> ScopeChunkSealing? {
        guard let key,
              let recording = storedRecordings.first(where: { $0.id == id }),
              let scope = scopeID(for: recording.projectScope),
              let scopeKey = accountKeys?.key(for: scope)
        else { return nil }

        return ScopeChunkSealing(local: LibraryCipher(key: key), scopeKey: scopeKey)
    }

    @discardableResult
    func createProject(named name: String, color: ProjectColor, at date: Date = .now) throws -> Project {
        let project = Project(name: name, color: color, createdAt: date)
        try writeProject(project)
        try hold(SymmetricKey(size: .bits256), forScope: project.id)
        return project
    }

    func saveProject(_ project: Project) throws {
        try writeProject(project)
    }

    func vocabulary(forProject id: UUID?) -> ProjectVocabulary {
        guard let id, let stored = storedVocabularies.first(where: { $0.projectID == id }) else {
            return ProjectVocabulary(projectID: id ?? UUID())
        }
        return stored
    }

    func saveVocabulary(_ vocabulary: ProjectVocabulary) throws {
        try writeVocabulary(vocabulary)
    }

    func confirmProjects(of recordingIDs: some Collection<UUID>, at date: Date = .now) throws {
        for id in recordingIDs {
            guard var recording = storedRecordings.first(where: { $0.id == id }), !recording.isProjectConfirmed else { continue }
            recording.assign(toProject: recording.projectID, at: date)
            try write(recording)
            journal?.record(.projectConfirmed, correlationID: id)
        }
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
        journal?.note(.libraryUnlockStarted)
        do {
            let key = try await Perf.trace("library.unlock.key") { try await keyRing.unlock(reason: reason) }
            let repository = services.makeRepository(key)
            storedRecordings = try Perf.measure("library.unlock.loadRecordings") { try repository.load() }
            try Perf.measure("library.unlock.loadProjects") {
                try loadProjects(with: key)
                try loadVocabularies(with: key)
                settings = LibrarySettings.load(from: services.settingsFile, cipher: LibraryCipher(key: key))
                accountKeys = try loadAccountKeys(with: key)
            }
            self.repository = repository
            self.key = key
            try Perf.measure("library.unlock.housekeeping") {
                try recoverInterruptedAudio(cipher: LibraryCipher(key: key))
                AudioChunkStore.discardPlaybackSidecars(in: services.audioRoot)
                discardUnfinishedImports()
                MeetingTileStore.discardLeftovers(in: services.audioRoot)
                try applyRetention()
            }
            state = .unlocked
            journal?.note(.libraryUnlocked)
            DevLog.event("library.unlocked", [
                "recordings": String(storedRecordings.count),
                "segments": String(storedRecordings.reduce(0) { $0 + $1.segments.count }),
                "projects": String(storedProjects.count),
            ])
            semanticIndex = SemanticIndex(engine: await Perf.trace("library.unlock.embeddingEngine") { await services.makeEmbeddingEngine() })
            semanticIndex.rebuildInBackground(storedRecordings)
        } catch {
            repository = nil
            projectRepository = nil
            vocabularyRepository = nil
            key = nil
            accountKeys = nil
            storedRecordings = []
            storedProjects = []
            storedVocabularies = []
            settings = LibrarySettings()
            state = .failed(error.localizedDescription)
            journal?.fail(.libraryUnlockFailed, error: error)
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
        updated.titleSource = .user
        try write(updated)
    }

    /// Deleting leaves a tombstone rather than erasing at once, so the same
    /// decision reaches other devices and the user has a window to undo it.
    func delete(_ recording: Recording, at date: Date = .now) throws {
        var deleted = recording
        deleted.deletedAt = date
        deleted.updatedAt = date
        try write(deleted)
        journal?.record(.recordingDeleted, correlationID: recording.id)
    }

    func restore(_ recording: Recording) throws {
        var restored = recording
        restored.deletedAt = nil
        restored.updatedAt = .now
        try write(restored)
    }

    /// Archiving hides a recording from the list without touching its audio,
    /// text, or sync. It stays recoverable from Storage settings.
    func archive(_ recording: Recording, at date: Date = .now) throws {
        var archived = recording
        archived.archivedAt = date
        archived.updatedAt = date
        try write(archived)
        journal?.record(.recordingArchived, correlationID: recording.id)
    }

    func unarchive(_ recording: Recording) throws {
        var unarchived = recording
        unarchived.archivedAt = nil
        unarchived.updatedAt = .now
        try write(unarchived)
        journal?.record(.recordingUnarchived, correlationID: recording.id)
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
        try journalingExport(of: recording) {
            let captured = try capturedAudio(forRecording: recording.id)
            return WAVFile.data(pcm: captured.pcm, format: captured.format)
        }
    }

    func audio(for recording: Recording, track: AudioTrack) throws -> Data {
        guard let key else { throw LibraryError.locked }

        return try journalingExport(of: recording) {
            try AudioChunkStore.audio(
                forRecording: recording.id,
                track: track,
                in: services.audioRoot,
                cipher: LibraryCipher(key: key)
            )
        }
    }

    private func journalingExport<Output>(of recording: Recording, _ work: () throws -> Output) throws -> Output {
        do {
            let output = try work()
            journal?.record(.exportFinished, correlationID: recording.id)
            return output
        } catch {
            journal?.fail(.exportFailed, error: error, correlationID: recording.id)
            throw error
        }
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
            try loadVocabularies(with: key)
            settings = LibrarySettings.load(from: services.settingsFile, cipher: LibraryCipher(key: key))
            accountKeys = try loadAccountKeys(with: key)
            self.repository = repository
            self.key = key
            state = .unlocked
            semanticIndex = SemanticIndex(engine: await services.makeEmbeddingEngine())
            semanticIndex.rebuildInBackground(storedRecordings)
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    func revokeOtherDevices(reason: String = String(localized: "Rotate your Still Library key")) async throws {
        guard key != nil else { throw LibraryError.locked }

        let newKey = try await keyRing.beginRotation(reason: reason)
        try rotate(to: newKey, keys: accountKeys?.renewingScopeKeys())
    }

    func join(
        _ invitation: AccountInvitation,
        reason: String = String(localized: "Join your other device's Still Library")
    ) async throws {
        guard key != nil, let accountKeys else { throw LibraryError.locked }

        let newKey = SymmetricKey(data: invitation.accountKey)
        try await keyRing.beginRotation(to: newKey, reason: reason)
        try rotate(to: newKey, keys: accountKeys.joining(invitation))
    }

    private func rotate(to newKey: SymmetricKey, keys: AccountKeys?) throws {
        guard let oldKey = key else { throw LibraryError.locked }

        let oldCipher = LibraryCipher(key: oldKey)
        let newCipher = LibraryCipher(key: newKey)
        let newRepository = services.makeRepository(newKey)
        let newProjectRepository = services.makeProjectRepository(newKey)
        let newVocabularyRepository = services.makeVocabularyRepository(newKey)

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
            for vocabulary in storedVocabularies {
                try newVocabularyRepository.save(vocabulary)
            }
            try settings.save(to: services.settingsFile, cipher: newCipher)
            try keys?.save(to: services.keysFile, cipher: newCipher)
        } catch {
            try? keyRing.abandonRotation()
            throw error
        }

        try keyRing.completeRotation()
        repository = newRepository
        projectRepository = newProjectRepository
        vocabularyRepository = newVocabularyRepository
        key = newKey
        accountKeys = keys
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

    var accountID: UUID? {
        accountKeys?.accountID
    }

    var accountCreatedAt: Date? {
        accountKeys?.createdAt
    }

    var knownScopes: [ProjectScope] {
        [.noProject] + storedProjects.map { .project($0.id) }
    }

    func scopeID(for scope: ProjectScope) -> UUID? {
        switch scope {
        case .project(let id): id
        case .noProject: accountKeys?.noProjectScopeID
        }
    }

    var heldScopeIDs: Set<UUID> {
        accountKeys?.heldScopeIDs ?? []
    }

    var requestedScopeIDs: Set<UUID> {
        Set(knownScopes.filter(projectSelection.includes).compactMap(scopeID(for:)))
    }

    func holds(_ scope: ProjectScope) -> Bool {
        scopeID(for: scope).map(heldScopeIDs.contains) ?? false
    }

    func storage(of scope: ProjectScope) -> ScopeStorage {
        if projectSelection.includes(scope) {
            return holds(scope) ? .stored : .waitingForKey
        }

        let keepsCopies = storedRecordings.contains { $0.projectScope == scope && $0.isProjectConfirmed }
        return holds(scope) || keepsCopies ? .leaving : .notStored
    }

    func scopeKey(for scope: UUID) -> SymmetricKey? {
        accountKeys?.key(for: scope)
    }

    func hold(_ scopeKey: SymmetricKey, forScope scope: UUID) throws {
        guard let key, var keys = accountKeys else { throw LibraryError.locked }

        keys.hold(scopeKey, for: scope)
        try keys.save(to: services.keysFile, cipher: LibraryCipher(key: key))
        accountKeys = keys
    }

    func confirmedRecordings(inScope scope: UUID) -> [Recording] {
        storedRecordings.filter { $0.isProjectConfirmed && scopeID(for: $0.projectScope) == scope }
    }

    func releaseScope(_ scope: UUID) throws {
        guard let key, var keys = accountKeys else { throw LibraryError.locked }

        for recording in confirmedRecordings(inScope: scope) {
            try purgeLocalCopy(ofRecording: recording.id)
        }
        keys.release(scope)
        try keys.save(to: services.keysFile, cipher: LibraryCipher(key: key))
        accountKeys = keys
    }

    func purgeLocalCopy(ofRecording id: UUID) throws {
        guard let repository else { throw LibraryError.locked }

        try repository.delete(id)
        try? AudioChunkStore.discard(AudioChunkStore.directory(forRecording: id, in: services.audioRoot))
        storedRecordings.removeAll { $0.id == id }
        semanticIndex.remove(id)
    }

    func accountInvitation() throws -> AccountInvitation {
        guard let key, let accountKeys else { throw LibraryError.locked }

        return AccountInvitation(
            accountKey: key.rawBytes,
            accountID: accountKeys.accountID,
            createdAt: accountKeys.createdAt,
            noProjectScopeID: accountKeys.noProjectScopeID
        )
    }

    func sharedAccountKeys() throws -> SharedAccountKeys {
        guard let accountKeys else { throw LibraryError.locked }

        return SharedAccountKeys(account: try accountInvitation(), scopeKeys: accountKeys.scopeKeys)
    }

    func wantsScope(_ scope: UUID) -> Bool {
        if scope == accountKeys?.noProjectScopeID {
            return projectSelection.includes(.noProject)
        }
        return projectSelection.includes(.project(scope))
    }

    func adopt(_ shared: SharedAccountKeys) async throws {
        guard key != nil, accountKeys != nil else { throw LibraryError.locked }

        if shared.account.accountID != accountID || shared.account.accountKey != key?.rawBytes {
            try await join(shared.account, reason: String(localized: "Join your other devices' Still Library"))
            journal?.record(.syncJoined)
        }
        guard let key, var keys = accountKeys else { throw LibraryError.locked }

        var changed = false
        for (scope, bytes) in shared.scopeKeys where wantsScope(scope) && keys.key(for: scope)?.rawBytes != bytes {
            keys.hold(SymmetricKey(data: bytes), for: scope)
            changed = true
        }
        guard changed else { return }
        try keys.save(to: services.keysFile, cipher: LibraryCipher(key: key))
        accountKeys = keys
    }

    func sealForAccount(_ data: Data) throws -> Data {
        guard let key else { throw LibraryError.locked }

        return try LibraryCipher(key: key).seal(data)
    }

    func openFromAccount(_ sealed: Data) throws -> Data {
        guard let key else { throw LibraryError.locked }

        return try LibraryCipher(key: key).open(sealed)
    }

    func syncChange(for recording: Recording, deviceID: UUID) throws -> SyncChange? {
        guard let scope = scopeID(for: recording.projectScope), let scopeKey = accountKeys?.key(for: scope) else {
            return nil
        }

        return SyncChange(
            id: recording.id,
            kind: .recording,
            updatedAt: recording.updatedAt,
            deviceID: deviceID,
            scopeID: scope,
            payload: try LibraryCipher(key: scopeKey).seal(try JSONEncoder().encode(recording))
        )
    }

    func openRecording(from change: SyncChange) throws -> Recording {
        guard let scope = change.scopeID, let scopeKey = accountKeys?.key(for: scope), let payload = change.payload else {
            throw LibraryCipherError.unreadable
        }

        let recording = try JSONDecoder().decode(Recording.self, from: try LibraryCipher(key: scopeKey).open(payload))
        guard recording.id == change.id, scopeID(for: recording.projectScope) == scope else {
            throw LibraryCipherError.unreadable
        }
        return recording
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
        let merged = local.map { Project.merge($0, remote) } ?? remote
        guard merged != local else { return }
        try writeProject(merged)
    }

    /// Sealed under the project's own scope key, exactly like a recording, so
    /// a device excluded from a project never receives its vocabulary.
    func syncChange(for vocabulary: ProjectVocabulary, deviceID: UUID) throws -> SyncChange? {
        guard let scopeKey = accountKeys?.key(for: vocabulary.projectID) else { return nil }

        return SyncChange(
            id: vocabulary.projectID,
            kind: .vocabulary,
            updatedAt: vocabulary.terms.map(\.updatedAt).max() ?? .distantPast,
            deviceID: deviceID,
            scopeID: vocabulary.projectID,
            payload: try LibraryCipher(key: scopeKey).seal(try JSONEncoder().encode(vocabulary))
        )
    }

    func openVocabulary(from change: SyncChange) throws -> ProjectVocabulary {
        guard let scope = change.scopeID, let scopeKey = accountKeys?.key(for: scope), let payload = change.payload else {
            throw LibraryCipherError.unreadable
        }

        let vocabulary = try JSONDecoder().decode(ProjectVocabulary.self, from: try LibraryCipher(key: scopeKey).open(payload))
        guard vocabulary.projectID == scope else { throw LibraryCipherError.unreadable }
        return vocabulary
    }

    func applyRemote(_ remote: ProjectVocabulary) throws {
        let local = storedVocabularies.first { $0.projectID == remote.projectID }
        let merged = local.map { ProjectVocabulary.merge($0, remote) } ?? remote
        guard merged != local else { return }
        try writeVocabulary(merged)
    }

    /// Matched against every stored Recording, tombstones included, so a copy
    /// that predates a deletion merges into it instead of arriving as new.
    func applyRemote(_ remote: Recording) throws {
        guard let local = storedRecordings.first(where: { $0.id == remote.id }) else {
            try write(remote)
            return
        }

        let merged = RecordingMerge.merge(local, remote)
        guard merged != local else { return }
        try write(merged)
    }

    func archive(_ recording: Recording, tracks: [AudioTrack]) throws -> Data {
        guard let key else { throw LibraryError.locked }

        return try journalingExport(of: recording) {
            try sealedArchive(of: recording, tracks: tracks, key: key)
        }
    }

    private func sealedArchive(of recording: Recording, tracks: [AudioTrack], key: SymmetricKey) throws -> Data {
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

    func importID(forContentDigest digest: Data) throws -> UUID {
        guard let key else { throw LibraryError.locked }

        return ImportIdentity.recordingID(forContentDigest: digest, key: key)
    }

    var availableImportCapacity: Int64? {
        services.availableCapacity(services.audioRoot)
    }

    func hasRecording(withID id: UUID) -> Bool {
        storedRecordings.contains { $0.id == id && !$0.isDeleted }
    }

    func stageImport(forRecording id: UUID, track: AudioTrack) throws -> AudioChunkWriter {
        guard let key else { throw LibraryError.locked }

        let staging = importStagingDirectory(forRecording: id)
        try? FileManager.default.removeItem(at: staging)
        return try AudioChunkWriter(
            directory: staging.appendingPathComponent(track.rawValue, isDirectory: true),
            cipher: LibraryCipher(key: key)
        )
    }

    func commitImport(forRecording id: UUID) throws {
        let destination = AudioChunkStore.directory(forRecording: id, in: services.audioRoot)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: importStagingDirectory(forRecording: id), to: destination)
    }

    func discardImport(forRecording id: UUID) {
        try? FileManager.default.removeItem(at: importStagingDirectory(forRecording: id))
        guard !storedRecordings.contains(where: { $0.id == id }) else { return }

        try? AudioChunkStore.discard(AudioChunkStore.directory(forRecording: id, in: services.audioRoot))
    }

    private var importStagingRoot: URL {
        services.audioRoot.appendingPathComponent(".imports", isDirectory: true)
    }

    private func importStagingDirectory(forRecording id: UUID) -> URL {
        importStagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func discardUnfinishedImports() {
        try? FileManager.default.removeItem(at: importStagingRoot)
    }

    func capturedAudio(forRecording id: UUID) throws -> (pcm: Data, format: AudioFormat) {
        guard let key else { throw LibraryError.locked }

        return try AudioChunkStore.mixed(
            forRecording: id,
            in: services.audioRoot,
            cipher: LibraryCipher(key: key)
        )
    }

    func debugAudioSource(forRecording id: UUID) -> DebugAudioSource? {
        guard let key else { return nil }

        return DebugAudioSource(recordingID: id, root: services.audioRoot, cipher: LibraryCipher(key: key), tracks: tracks(forRecording: id))
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

    func review(_ itemID: String, inRecording recordingID: UUID, as review: MemoryReview, at date: Date = .now) throws {
        try updateMemoryItem(itemID, inRecording: recordingID, at: date) { $0.reviewed(review, at: date) }
    }

    func edit(_ itemID: String, inRecording recordingID: UUID, to text: String, at date: Date = .now) throws {
        try updateMemoryItem(itemID, inRecording: recordingID, at: date) { $0.edited(to: text, at: date) }
    }

    func acceptedTasks(inProject projectID: UUID) -> [SourcedItem] {
        SourcedItem.acceptedTasks(in: recordings, project: projectID)
    }

    func projectHistory(_ projectID: UUID) -> ProjectHistory {
        ProjectHistory(recordings: recordings, project: projectID)
    }

    func dashboard(at date: Date = .now) -> Dashboard {
        let key = dashboardCacheKey(date: date)
        if key == dashboardCache.key, let cached = dashboardCache.dashboard {
            return cached
        }
        let built = Dashboard(recordings: recordings, now: date)
        dashboardCache = (key, built)
        return built
    }

    private func dashboardCacheKey(date: Date) -> String {
        let fingerprint = (try? JSONEncoder().encode(storedRecordings))?.hashValue ?? 0
        let minute = Int(date.timeIntervalSinceReferenceDate / 60)
        return "\(fingerprint)|\(projectSelection)|\(minute)"
    }

    private func updateMemoryItem(
        _ itemID: String,
        inRecording recordingID: UUID,
        at date: Date,
        _ change: (MemoryItem) -> MemoryItem
    ) throws {
        guard var recording = storedRecordings.first(where: { $0.id == recordingID }),
              let memory = recording.memory,
              memory.item(withID: itemID) != nil
        else { return }

        recording.memory = memory.updating(itemID, change)
        recording.updatedAt = max(recording.updatedAt, date)
        try write(recording)
    }

    func renameSpeaker(_ speaker: Speaker, to name: String, in recording: Recording) throws {
        try write(recording.renamingSpeaker(speaker, to: name))
        try rememberOwner(speaker, as: name)
    }

    var speakerNaming: SpeakerNamingContext {
        SpeakerNamingContext(profiles: rememberedVoiceProfiles, ownerName: settings.ownerName)
    }

    var rememberedVoiceProfiles: [VoiceProfile] {
        let keys = settings.rememberedVoiceKeys
        return VoiceProfiles.from(recordings).filter { keys.contains(VoiceProfiles.key(for: $0.name)) }
    }

    func remembersVoice(of name: String) -> Bool {
        settings.rememberedVoiceKeys.contains(VoiceProfiles.key(for: name))
    }

    func rememberVoice(of name: String) throws {
        try updateSettings { $0.rememberedVoices = $0.rememberedVoiceKeys.union([VoiceProfiles.key(for: name)]) }
    }

    func forgetVoice(of name: String) throws {
        try updateSettings { $0.rememberedVoices = $0.rememberedVoiceKeys.subtracting([VoiceProfiles.key(for: name)]) }
    }

    private func updateSettings(_ change: (inout LibrarySettings) -> Void) throws {
        guard let key else { throw LibraryError.locked }

        var updated = settings
        change(&updated)
        try updated.save(to: services.settingsFile, cipher: LibraryCipher(key: key))
        settings = updated
    }

    var ownerName: String? {
        settings.ownerName
    }

    func setOwnerName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try updateSettings { $0.ownerName = trimmed.isEmpty ? nil : trimmed }
    }

    func rememberOwner(_ speaker: Speaker, as name: String) throws {
        guard speaker.isYou, settings.ownerName == nil else { return }
        try setOwnerName(name)
    }

    /// Audio left behind by a termination becomes a Recording on the next unlock.
    /// Adoption is keyed by the recording id, so repeating it creates no duplicate.
    private func recoverInterruptedAudio(cipher: LibraryCipher) throws {
        let known = Set(storedRecordings.map(\.id))
        let interrupted = try AudioChunkStore.interruptedRecordings(
            in: services.audioRoot,
            cipher: cipher,
            unclaimedBesides: known
        )

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

    private func loadAccountKeys(with key: SymmetricKey) throws -> AccountKeys {
        let cipher = LibraryCipher(key: key)
        if let stored = try AccountKeys.load(from: services.keysFile, cipher: cipher) {
            return stored
        }

        let founded = AccountKeys.founding(projects: storedProjects.map(\.id), at: .now)
        try founded.save(to: services.keysFile, cipher: cipher)
        return founded
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

    private func loadVocabularies(with key: SymmetricKey) throws {
        let vocabularyRepository = services.makeVocabularyRepository(key)
        storedVocabularies = try vocabularyRepository.load()
        self.vocabularyRepository = vocabularyRepository
    }

    private func writeVocabulary(_ vocabulary: ProjectVocabulary) throws {
        guard let vocabularyRepository else { throw LibraryError.locked }

        try vocabularyRepository.save(vocabulary)
        if let index = storedVocabularies.firstIndex(where: { $0.projectID == vocabulary.projectID }) {
            storedVocabularies[index] = vocabulary
        } else {
            storedVocabularies.append(vocabulary)
        }
    }

    private func write(_ incoming: Recording) throws {
        guard let repository else { throw LibraryError.locked }

        let recording = storedRecordings.first { $0.id == incoming.id }
            .map { incoming.keepingLatestProject(of: $0).keepingMemory(of: $0) } ?? incoming
        try Perf.measure("library.write", ["recordingID": recording.id.uuidString, "segments": String(recording.segments.count)]) {
            try repository.save(recording)
        }
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
