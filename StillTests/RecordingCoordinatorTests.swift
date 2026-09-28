import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct RecordingCoordinatorTests {
    @Test
    func reportsEveryPhaseOfOneSession() async throws {
        let context = try makeContext()
        let library = try await makeUnlockedLibrary(context: context)
        let session = FakeTranscriptionSession()
        let transcriber = StubOfflineTranscriber()
        let coordinator = makeCoordinator(library: library, session: session, transcriber: transcriber)

        #expect(coordinator.phase == .idle)

        await coordinator.start()

        #expect(coordinator.phase == .recording)
        #expect(coordinator.isRecording)

        await coordinator.stopAndSave()

        #expect(coordinator.phase == .idle)
        #expect(library.recordings.count == 1)
    }

    @Test
    func theShortcutTogglesTheSameSessionTheWindowSees() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let coordinator = makeCoordinator(library: library, session: FakeTranscriptionSession())

        await coordinator.toggle()

        #expect(coordinator.isRecording)

        await coordinator.toggle()

        #expect(!coordinator.isRecording)
        #expect(library.recordings.count == 1)
    }

    @Test
    func nothingStartsBeforeStillIsReadyToRecord() async throws {
        let library = makeLibrary(context: try makeContext(), audioRoot: try Scratch().directory)
        let coordinator = RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { FakeTranscriptionSession() },
            makeFinalTranscription: { FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600) },
            isReady: { false }
        )

        await coordinator.start()

        #expect(!coordinator.canStart)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.workflow == nil)
    }

    @Test
    func aLockedLibraryBecomesARecoverableFailure() async throws {
        let library = makeLibrary(context: try makeContext(), audioRoot: try Scratch().directory)
        let coordinator = makeCoordinator(library: library, session: FakeTranscriptionSession())

        await coordinator.start()

        #expect(coordinator.phase == .failed(LibraryError.locked.localizedDescription))
        #expect(!coordinator.isRecording)
    }

    @Test
    func discardingLeavesNothingBehind() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let coordinator = makeCoordinator(library: library, session: FakeTranscriptionSession())

        await coordinator.start()
        await coordinator.cancel()

        #expect(coordinator.phase == .idle)
        #expect(library.recordings.isEmpty)
    }

    @Test
    func stopAndSaveListsTheRecordingBeforeTheTranscriptRenders() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let session = FakeTranscriptionSession()
        session.transcript = "Ship the private beta on Friday"
        let notifier = FakeNotifier()
        let coordinator = makeCoordinator(library: library, session: session, notifier: notifier)

        await coordinator.start()
        await coordinator.stopAndSave()

        #expect(coordinator.phase == .idle)
        let placeholder = try #require(library.recordings.first)
        #expect(placeholder.transcript == "Ship the private beta on Friday")
        #expect(placeholder.isProcessing)
        #expect(coordinator.processingProgress[placeholder.id] != nil)

        await coordinator.waitForBackgroundProcessing()

        let finished = try #require(library.recordings.first)
        #expect(finished.transcript == "Transcribed after saving")
        #expect(!finished.isProcessing)
        #expect(finished.note != nil)
        #expect(coordinator.processingProgress[placeholder.id] == nil)
        #expect(notifier.readyTitles == [finished.title])
    }

    @Test
    func silenceLeavesNothingBehind() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let session = FakeTranscriptionSession()
        session.transcript = "   "
        let transcriber = StubOfflineTranscriber()
        transcriber.result = ""
        let notifier = FakeNotifier()
        let coordinator = makeCoordinator(library: library, session: session, transcriber: transcriber, notifier: notifier)

        await coordinator.start()
        await coordinator.stopAndSave()
        await coordinator.waitForBackgroundProcessing()

        #expect(library.recordings.isEmpty)
        #expect(notifier.readyTitles.isEmpty)
    }

    @Test
    func aFailedFinalPassKeepsTheLiveDraft() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let session = FakeTranscriptionSession()
        session.transcript = "Heard while recording"
        let transcriber = StubOfflineTranscriber()
        transcriber.error = TranscriptionError.modelNotInstalled
        let notifier = FakeNotifier()
        let coordinator = makeCoordinator(library: library, session: session, transcriber: transcriber, notifier: notifier)

        await coordinator.start()
        await coordinator.stopAndSave()
        await coordinator.waitForBackgroundProcessing()

        let recording = try #require(library.recordings.first)
        #expect(recording.transcript == "Heard while recording")
        #expect(!recording.isProcessing)
        #expect(notifier.readyTitles.count == 1)
    }

    @Test
    func namesTheSpeakersAfterTheFinalTranscript() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let session = FakeTranscriptionSession()
        var askedAbout: Date?
        let coordinator = RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { session },
            makeFinalTranscription: { FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600) },
            makeSpeakerSeparation: {
                SpeakerSeparation(diarizer: StubDiarizer(turns: [SpeakerTurn(speaker: 0, start: 0, end: 5)]))
            },
            expectedParticipants: { date in
                askedAbout = date
                return ["Anna Kowalska", "Ben Olsen"]
            }
        )

        await coordinator.start()
        await coordinator.stopAndSave()
        await coordinator.waitForBackgroundProcessing()

        let recording = try #require(library.recordings.first)
        #expect(!recording.speakers.isEmpty)
        #expect(recording.segments.allSatisfy { segment in recording.speakers.map(\.id).contains(segment.speakerID) })
        #expect(recording.expectedParticipants == ["Anna Kowalska", "Ben Olsen"])
        #expect(askedAbout != nil)
    }

    @Test
    func deletingWhileProcessingResurrectsNothing() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let session = FakeTranscriptionSession()
        session.transcript = "Doomed thought"
        let transcriber = GatedOfflineTranscriber()
        let coordinator = makeCoordinator(library: library, session: session, transcriber: transcriber)

        await coordinator.start()
        await coordinator.stopAndSave()
        let doomed = try #require(library.recordings.first)

        while !transcriber.entered {
            await Task.yield()
        }
        try library.delete(doomed)
        coordinator.cancelProcessing(for: doomed.id)
        transcriber.open()
        await coordinator.waitForBackgroundProcessing()

        #expect(library.recordings.isEmpty)
        #expect(coordinator.processingProgress[doomed.id] == nil)
    }

    @Test
    func renamingWhileProcessingSurvivesTheFinishedTranscript() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let session = FakeTranscriptionSession()
        session.transcript = "Draft words here"
        let transcriber = GatedOfflineTranscriber()
        let coordinator = makeCoordinator(library: library, session: session, transcriber: transcriber)

        await coordinator.start()
        await coordinator.stopAndSave()
        let placeholder = try #require(library.recordings.first)
        while !transcriber.entered {
            await Task.yield()
        }
        try library.rename(placeholder, to: "User Title")
        transcriber.open()
        await coordinator.waitForBackgroundProcessing()

        let recording = try #require(library.recordings.first)
        #expect(recording.title == "User Title")
        #expect(recording.transcript == "Transcribed after saving")
        #expect(!recording.isProcessing)
    }

    @Test
    func noteTextWrittenWhileProcessingSurvivesTheFinishedNote() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let session = FakeTranscriptionSession()
        session.transcript = "Draft words here"
        let transcriber = GatedOfflineTranscriber()
        let coordinator = makeCoordinator(library: library, session: session, transcriber: transcriber)

        await coordinator.start()
        await coordinator.stopAndSave()
        var placeholder = try #require(library.recordings.first)
        while !transcriber.entered {
            await Task.yield()
        }
        placeholder.note = Note(template: .personalNote, userText: "My take")
        try library.save(placeholder)
        transcriber.open()
        await coordinator.waitForBackgroundProcessing()

        let recording = try #require(library.recordings.first)
        #expect(recording.note?.userText == "My take")
        #expect(!(recording.note?.summary.isEmpty ?? true))
        #expect(!recording.isProcessing)
    }

    private func makeCoordinator(
        library: Library,
        session: FakeTranscriptionSession,
        transcriber: OfflineTranscriber = StubOfflineTranscriber(),
        notifier: RecordingNotifier? = nil
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { session },
            makeFinalTranscription: { FinalTranscription(transcriber: transcriber, windowSeconds: 3_600) },
            notifier: notifier
        )
    }

    private func makeUnlockedLibrary(context: ModelContext) async throws -> Library {
        let library = makeLibrary(context: context, audioRoot: try Scratch().directory)
        await library.unlock()
        return library
    }

    private func makeLibrary(context: ModelContext, audioRoot: URL) -> Library {
        Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated {
                        EncryptedRecordingRepository(context: context, key: key)
                    }
                },
                makeRecorder: { key in
                    MainActor.assumeIsolated {
                        WritingRecorder(root: audioRoot, cipher: LibraryCipher(key: key))
                    }
                }
            )
        )
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }
}

@MainActor
final class FakeNotifier: RecordingNotifier {
    private(set) var authorizations = 0
    private(set) var readyTitles: [String] = []

    func requestAuthorization() async {
        authorizations += 1
    }

    func notifyReady(title: String) async {
        readyTitles.append(title)
    }
}

final class GatedOfflineTranscriber: OfflineTranscriber, @unchecked Sendable {
    var result = "Transcribed after saving"
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isEntered = false

    var entered: Bool {
        lock.withLock { isEntered }
    }

    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment] {
        lock.withLock { isEntered = true }
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
        guard !result.isEmpty else { return [] }
        return [TranscriptSegment(start: 0, end: 5, text: result, language: "en", confidence: 0.9)]
    }

    func open() {
        lock.withLock { continuation }?.resume()
    }
}

@MainActor
final class WritingRecorder: AudioRecorder {
    private let root: URL
    private let cipher: LibraryCipher
    private var writer: AudioChunkWriter?
    private var directory: URL?

    init(root: URL, cipher: LibraryCipher) {
        self.root = root
        self.cipher = cipher
    }

    func start(recordingID: UUID) async throws {
        directory = AudioChunkStore.directory(forRecording: recordingID, in: root)
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: recordingID, track: .microphone, in: root),
            cipher: cipher
        )
        try writer.append(Data(repeating: 4, count: AudioFormat.transcription.bytesPerSecond))
        self.writer = writer
    }

    func finish() async throws {
        try writer?.finish()
        writer = nil
    }

    func discard() async {
        try? writer?.finish()
        writer = nil
        if let directory { try? AudioChunkStore.discard(directory) }
        directory = nil
    }
}
