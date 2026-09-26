import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct RecordingPersistenceTests {
    @Test
    func deletingEveryRecordingStaysDeletedAfterARelaunch() async throws {
        let source = FakeDeviceKeySource()
        let container = try makeContainer()
        let audioRoot = try Scratch().directory
        let at = Date()

        let first = await makeLibrary(source: source, container: container, audioRoot: audioRoot)
        try first.add(Recording(title: "One", transcript: "One.", duration: 60))
        try first.add(Recording(title: "Two", transcript: "Two.", duration: 60))
        for recording in first.recordings {
            try first.delete(recording, at: at)
        }
        #expect(first.recordings.isEmpty)

        let relaunched = await makeLibrary(source: source, container: container, audioRoot: audioRoot)

        #expect(relaunched.recordings.isEmpty)
        #expect(relaunched.deletedRecordings.count == 2)
        #expect(relaunched.deletedRecordings.allSatisfy { $0.updatedAt == at && $0.deletedAt == at })
    }

    @Test
    func archivingStaysArchivedAfterARelaunch() async throws {
        let source = FakeDeviceKeySource()
        let container = try makeContainer()
        let audioRoot = try Scratch().directory

        let first = await makeLibrary(source: source, container: container, audioRoot: audioRoot)
        try first.add(Recording(title: "One", transcript: "One.", duration: 60))
        let recording = try #require(first.recordings.first)
        let at = Date()
        try first.archive(recording, at: at)

        let relaunched = await makeLibrary(source: source, container: container, audioRoot: audioRoot)

        #expect(relaunched.recordings.isEmpty)
        #expect(relaunched.archivedRecordings.map(\.id) == [recording.id])
        #expect(relaunched.archivedRecordings.allSatisfy { $0.updatedAt == at && $0.archivedAt == at })
    }

    private func makeLibrary(source: FakeDeviceKeySource, container: ModelContainer, audioRoot: URL) async -> Library {
        let context = ModelContext(container)
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

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }
}
