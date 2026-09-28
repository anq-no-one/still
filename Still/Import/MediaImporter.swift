import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
protocol MediaImportLibrary: RecordingLibrary {
    var defaultProjectID: UUID? { get }
    var journal: DiagnosticJournal? { get }
    var availableImportCapacity: Int64? { get }

    func importID(forContentDigest digest: Data) throws -> UUID
    func hasRecording(withID id: UUID) -> Bool
    func stageImport(forRecording id: UUID, track: AudioTrack) throws -> AudioChunkWriter
    func commitImport(forRecording id: UUID) throws
    func discardImport(forRecording id: UUID)
}

extension Library: MediaImportLibrary {}

@MainActor
@Observable
final class MediaImporter {
    enum Phase: Equatable {
        case idle
        case reading
        case decoding(Double)
        case transcribing(Double)
        case imported(UUID)
        case failed(String)
    }

    static let track = AudioTrack.system
    static let contentTypes: [UTType] = [.audio, .movie]
    static let spaceReserve: Int64 = 50_000_000
    #if os(iOS)
    nonisolated static let handOverFolders = [
        URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory),
        URL.temporaryDirectory,
    ]
    #else
    nonisolated static let handOverFolders: [URL] = []
    #endif

    private let library: MediaImportLibrary
    private let makeFinalTranscription: () -> FinalTranscription
    private let makeSpeakerSeparation: () -> SpeakerSeparation
    private let noteBuilder: GroundedNoteBuilder
    private let isReady: @MainActor () -> Bool
    private let now: () -> Date
    private let handOverFolders: [URL]

    private(set) var phase: Phase = .idle
    private(set) var fileName: String?
    private(set) var failedFile: URL?
    private var task: Task<Void, Never>?

    init(
        library: MediaImportLibrary,
        makeFinalTranscription: @escaping () -> FinalTranscription,
        makeSpeakerSeparation: @escaping () -> SpeakerSeparation = { .trackBased },
        noteBuilder: GroundedNoteBuilder = GroundedNoteBuilder(),
        isReady: @escaping @MainActor () -> Bool = { true },
        now: @escaping () -> Date = Date.init,
        handOverFolders: [URL] = MediaImporter.handOverFolders
    ) {
        self.library = library
        self.makeFinalTranscription = makeFinalTranscription
        self.makeSpeakerSeparation = makeSpeakerSeparation
        self.noteBuilder = noteBuilder
        self.isReady = isReady
        self.now = now
        self.handOverFolders = handOverFolders
    }

    var isImporting: Bool {
        switch phase {
        case .reading, .decoding, .transcribing: true
        case .idle, .imported, .failed: false
        }
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var canStart: Bool {
        isReady() && !isImporting
    }

    @discardableResult
    func start(_ url: URL) -> Task<Void, Never>? {
        guard canStart else { return nil }

        if let failedFile, failedFile != url { releaseHandedOver(failedFile) }
        fileName = url.lastPathComponent
        failedFile = nil
        phase = .reading
        let task = Task { await run(url) }
        self.task = task
        return task
    }

    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard let failedFile else { return nil }
        return start(failedFile)
    }

    func cancel() {
        task?.cancel()
    }

    func dismiss() {
        guard !isImporting else { return }
        if let failedFile { releaseHandedOver(failedFile) }
        phase = .idle
        fileName = nil
        failedFile = nil
    }

    private func run(_ url: URL) async {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

        var recordingID: UUID?
        do {
            let source = try MediaFile.inspect(url)
            let id = try library.importID(forContentDigest: try await background { try await source.contentDigest() })
            guard !library.hasRecording(withID: id) else {
                releaseHandedOver(url)
                phase = .imported(id)
                return
            }

            let sound = try await source.soundTrack()
            try ensureSpace(for: sound)
            recordingID = id
            library.journal?.record(.importStarted, correlationID: id)
            let duration = try await decode(sound, as: id)
            try Task.checkCancellation()
            try library.commitImport(forRecording: id)

            phase = .transcribing(0)
            try await finalizer().finalize(
                RecordingFinalizer.Draft(
                    id: id,
                    title: source.title,
                    createdAt: source.createdAt ?? now(),
                    duration: duration,
                    suggestedProjectID: library.defaultProjectID,
                    requiresTranscript: true,
                    importedFrom: source.imported
                ),
                progress: report { .transcribing($0) }
            )
            library.journal?.record(.importSaved, correlationID: id)
            releaseHandedOver(url)
            phase = .imported(id)
        } catch is CancellationError {
            discard(recordingID)
            releaseHandedOver(url)
            phase = .idle
            fileName = nil
        } catch {
            discard(recordingID)
            library.journal?.fail(.importFailed, error: error, correlationID: recordingID ?? UUID())
            failedFile = url
            phase = .failed(error.localizedDescription)
        }
    }

    private func ensureSpace(for sound: SoundTrack) throws {
        guard let available = library.availableImportCapacity else { return }
        guard available >= sound.decodedSize() + Self.spaceReserve else { throw MediaImportError.insufficientSpace }
    }

    private func decode(_ sound: SoundTrack, as id: UUID) async throws -> TimeInterval {
        phase = .decoding(0)
        let writer = try library.stageImport(forRecording: id, track: Self.track)
        let progress = report { .decoding($0) }
        return try await background {
            try await sound.decode(into: writer, progress: progress)
        }
    }

    private func background<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func releaseHandedOver(_ url: URL) {
        guard handOverFolders.contains(where: { Self.isInside($0, url) }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func isInside(_ directory: URL, _ url: URL) -> Bool {
        let folder = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let file = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return file.count > folder.count && Array(file.prefix(folder.count)) == folder
    }

    private func discard(_ recordingID: UUID?) {
        guard let recordingID else { return }
        library.discardImport(forRecording: recordingID)
    }

    private func finalizer() -> RecordingFinalizer {
        RecordingFinalizer(
            finalTranscription: makeFinalTranscription(),
            speakerSeparation: makeSpeakerSeparation(),
            noteBuilder: noteBuilder,
            library: library
        )
    }

    private func report(_ stage: @escaping @Sendable (Double) -> Phase) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in self?.advance(to: stage(fraction)) }
        }
    }

    private func advance(to next: Phase) {
        switch (phase, next) {
        case (.decoding(let current), .decoding(let fraction)) where fraction > current,
             (.transcribing(let current), .transcribing(let fraction)) where fraction > current:
            phase = next
        default:
            break
        }
    }
}
