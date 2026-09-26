import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct RecordingArchiveTests {
    @Test
    func archivingHidesFromTheListButKeepsContent() async throws {
        let context = try makeContext()
        let library = makeLibrary(source: FakeDeviceKeySource(), context: context)
        await library.unlock()
        let recording = Recording(title: "Standup", transcript: "shipped it", duration: 30)

        try library.add(recording)
        try library.archive(recording)

        #expect(library.recordings.isEmpty)
        #expect(library.archivedRecordings.map(\.id) == [recording.id])
        #expect(library.archivedRecordings.first?.title == "Standup")
        #expect(library.archivedRecordings.first?.transcript == "shipped it")
    }

    @Test
    func unarchivingReturnsToTheList() async throws {
        let context = try makeContext()
        let library = makeLibrary(source: FakeDeviceKeySource(), context: context)
        await library.unlock()
        let recording = Recording(title: "Standup", transcript: "shipped it", duration: 30)

        try library.add(recording)
        try library.archive(recording)
        try library.unarchive(recording)

        #expect(library.recordings.map(\.id) == [recording.id])
        #expect(library.archivedRecordings.isEmpty)
    }

    @Test
    func archiveOnEitherDeviceWinsTheMerge() {
        let id = UUID()
        let archived = Recording(
            id: id,
            title: "Call",
            transcript: "text",
            duration: 30,
            archivedAt: Date(timeIntervalSince1970: 100)
        )
        let open = Recording(
            id: id,
            title: "Call",
            transcript: "text",
            duration: 30,
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(RecordingMerge.merge(archived, open).isArchived)
        #expect(RecordingMerge.merge(open, archived).isArchived)
        #expect(!RecordingMerge.merge(open, open).isArchived)
    }

    @Test
    func payloadsWrittenBeforeArchivingStillOpen() throws {
        let old = """
        {"id":"\(UUID().uuidString)","title":"Old","transcript":"words",\
        "segments":[],"speakers":[],"createdAt":0,"duration":30,"updatedAt":0}
        """

        let recording = try JSONDecoder().decode(Recording.self, from: Data(old.utf8))

        #expect(!recording.isArchived)
        #expect(recording.title == "Old")
    }

    private func makeLibrary(
        source: FakeDeviceKeySource,
        context: ModelContext,
        audioRoot: URL = URL.temporaryDirectory.appending(path: "still-tests/\(UUID().uuidString)")
    ) -> Library {
        Library(
            keyRing: LibraryKeyRing(source: source),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated {
                        EncryptedRecordingRepository(context: context, key: key)
                    }
                },
                makeRecorder: { _ in
                    MainActor.assumeIsolated { SpyAudioRecorder() }
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
