import Foundation
import Observation

@MainActor
protocol AudioImportLibrary: RecordingLibrary {
    var defaultProjectID: UUID? { get }

    func importID(forContentDigest digest: Data) throws -> UUID
    func hasRecording(withID id: UUID) -> Bool
    func stageImport(forRecording id: UUID, track: AudioTrack) throws -> AudioChunkWriter
    func commitImport(forRecording id: UUID) throws
    func discardImport(forRecording id: UUID)
}

extension Library: AudioImportLibrary {}

@MainActor
@Observable
final class AudioImporter {
    enum Phase: Equatable {
        case idle
        case reading
        case decoding(Double)
        case transcribing(Double)
        case imported(UUID)
        case failed(String)
    }

    static let track = AudioTrack.system

    private let library: AudioImportLibrary
    private let makeFinalTranscription: () -> FinalTranscription
    private let makeSpeakerSeparation: () -> SpeakerSeparation
    private let noteBuilder: GroundedNoteBuilder
    private let isReady: @MainActor () -> Bool
    private let now: () -> Date

    private(set) var phase: Phase = .idle
    private(set) var fileName: String?
    private(set) var failedFile: URL?
    private var task: Task<Void, Never>?

    init(
        library: AudioImportLibrary,
        makeFinalTranscription: @escaping () -> FinalTranscription,
        makeSpeakerSeparation: @escaping () -> SpeakerSeparation = { .trackBased },
        noteBuilder: GroundedNoteBuilder = GroundedNoteBuilder(),
        isReady: @escaping @MainActor () -> Bool = { true },
        now: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.makeFinalTranscription = makeFinalTranscription
        self.makeSpeakerSeparation = makeSpeakerSeparation
        self.noteBuilder = noteBuilder
        self.isReady = isReady
        self.now = now
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
        phase = .idle
        fileName = nil
        failedFile = nil
    }

    private func run(_ url: URL) async {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

        var recordingID: UUID?
        do {
            let source = try AudioFileSource.inspect(url)
            let id = try library.importID(forContentDigest: try await source.contentDigest())
            guard !library.hasRecording(withID: id) else {
                phase = .imported(id)
                return
            }

            recordingID = id
            let duration = try await decode(source, as: id)
            try Task.checkCancellation()
            try library.commitImport(forRecording: id)

            phase = .transcribing(0)
            try await finalizer().finalize(
                RecordingFinalizer.Draft(
                    id: id,
                    title: source.title,
                    createdAt: source.createdAt ?? now(),
                    duration: duration,
                    projectID: library.defaultProjectID,
                    requiresTranscript: true
                ),
                progress: report { .transcribing($0) }
            )
            phase = .imported(id)
        } catch is CancellationError {
            discard(recordingID)
            phase = .idle
            fileName = nil
        } catch {
            discard(recordingID)
            failedFile = url
            phase = .failed(error.localizedDescription)
        }
    }

    private func decode(_ source: AudioFileSource, as id: UUID) async throws -> TimeInterval {
        phase = .decoding(0)
        let writer = try library.stageImport(forRecording: id, track: Self.track)
        return try await source.decode(into: writer, progress: report { .decoding($0) })
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
