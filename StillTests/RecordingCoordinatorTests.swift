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

    private func makeCoordinator(
        library: Library,
        session: FakeTranscriptionSession,
        transcriber: StubOfflineTranscriber = StubOfflineTranscriber()
    ) -> RecordingCoordinator {
        RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { session },
            makeFinalTranscription: { FinalTranscription(transcriber: transcriber, windowSeconds: 3_600) }
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
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
