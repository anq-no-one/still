import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct InterruptedFinalizationTests {
    @Test
    func audioThatFinishedRecordingButNeverFinishedProcessingSurvivesARelaunch() async throws {
        let source = FakeDeviceKeySource()
        let context = try makeContext()
        let audioRoot = try Scratch().directory
        let id = UUID()

        let first = await makeLibrary(source: source, context: context, audioRoot: audioRoot)
        let recorder = try first.makeRecorder()
        try await recorder.start(recordingID: id)
        try await recorder.finish()

        let relaunched = await makeLibrary(source: source, context: context, audioRoot: audioRoot)

        #expect(relaunched.recordings.map(\.id) == [id])
        #expect(relaunched.tracks(forRecording: id) == [.microphone])
    }

    @Test
    func aRecoveredRecordingIsTranscribedAfterTheRelaunch() async throws {
        let source = FakeDeviceKeySource()
        let context = try makeContext()
        let audioRoot = try Scratch().directory
        let id = UUID()
        let first = await makeLibrary(source: source, context: context, audioRoot: audioRoot)
        let recorder = try first.makeRecorder()
        try await recorder.start(recordingID: id)
        try await recorder.finish()

        let relaunched = await makeLibrary(source: source, context: context, audioRoot: audioRoot)
        let transcriber = StubOfflineTranscriber()
        transcriber.result = "Quarterly numbers look fine"
        let coordinator = RecordingCoordinator(
            library: relaunched,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { FakeTranscriptionSession() },
            makeFinalTranscription: { FinalTranscription(transcriber: transcriber, windowSeconds: 3_600) }
        )

        await coordinator.finishInterruptedProcessing()
        await coordinator.finishInterruptedProcessing()

        let recording = try #require(relaunched.recordings.first)
        #expect(relaunched.recordings.count == 1)
        #expect(recording.id == id)
        #expect(recording.transcript.contains("Quarterly"))
        #expect(transcriber.calls == 1)
    }

    private func makeLibrary(source: FakeDeviceKeySource, context: ModelContext, audioRoot: URL) async -> Library {
        let library = Library(
            keyRing: LibraryKeyRing(source: source),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { key in
                    MainActor.assumeIsolated { WritingRecorder(root: audioRoot, cipher: LibraryCipher(key: key)) }
                }
            )
        )
        await library.unlock()
        return library
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }
}
