import Foundation
import SwiftData
import Testing
@testable import Still

struct RetentionSweepTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    @Test
    func theDefaultKeepsAudioUntilTheUserDeletesIt() {
        let recording = aged(days: 500)

        let sweep = Retention.sweep(
            recordings: [recording],
            policy: .forever,
            audioDirectories: [recording.id],
            now: now
        )

        #expect(sweep.isEmpty)
    }

    @Test
    func aPolicyDropsOldAudioAndKeepsTheText() {
        let old = aged(days: 100)
        let recent = aged(days: 10)

        let sweep = Retention.sweep(
            recordings: [old, recent],
            policy: .days90,
            audioDirectories: [old.id, recent.id],
            now: now
        )

        #expect(sweep.audioToDelete == [old.id])
        #expect(sweep.recordingsToPurge.isEmpty)
    }

    @Test
    func aDeletedRecordingStaysRestorableForTheWindow() {
        var justDeleted = aged(days: 10)
        justDeleted.deletedAt = now.addingTimeInterval(-86_400)
        var longDeleted = aged(days: 100)
        longDeleted.deletedAt = now.addingTimeInterval(-Retention.recoveryWindow - 1)

        let sweep = Retention.sweep(
            recordings: [justDeleted, longDeleted],
            policy: .forever,
            audioDirectories: [justDeleted.id, longDeleted.id],
            now: now
        )

        #expect(sweep.recordingsToPurge == [longDeleted.id])
    }

    @Test
    func aDeletedRecordingIsNotAlsoSweptByThePolicy() {
        var deleted = aged(days: 200)
        deleted.deletedAt = now

        let sweep = Retention.sweep(
            recordings: [deleted],
            policy: .days30,
            audioDirectories: [deleted.id],
            now: now
        )

        #expect(sweep.audioToDelete.isEmpty)
    }

    @Test
    func audioWithNoRecordingIsRemoved() {
        let orphan = UUID()

        let sweep = Retention.sweep(recordings: [], policy: .forever, audioDirectories: [orphan], now: now)

        #expect(sweep.orphanAudio == [orphan])
    }

    private func aged(days: Int) -> Recording {
        Recording(
            title: "Recording",
            transcript: "text",
            createdAt: now.addingTimeInterval(-Double(days) * 86_400),
            duration: 60
        )
    }
}

@MainActor
struct LibraryRetentionTests {
    @Test
    func deletingHidesTheRecordingButKeepsItRestorable() async throws {
        let library = try await makeLibrary()
        let recording = Recording(title: "Draft", transcript: "text", duration: 30)
        try library.add(recording)

        try library.delete(recording)

        #expect(library.recordings.isEmpty)
        #expect(library.deletedRecordings.map(\.id) == [recording.id])

        try library.restore(try #require(library.deletedRecordings.first))

        #expect(library.recordings.map(\.id) == [recording.id])
    }

    @Test
    func anExpiredTombstoneIsPurgedAndDoesNotComeBack() async throws {
        let library = try await makeLibrary()
        let recording = Recording(title: "Draft", transcript: "text", duration: 30)
        try library.add(recording)
        try library.delete(recording, at: Date(timeIntervalSince1970: 0))

        try library.applyRetention(now: Date(timeIntervalSince1970: Retention.recoveryWindow + 1))

        #expect(library.recordings.isEmpty)
        #expect(library.deletedRecordings.isEmpty)

        await library.unlock()

        #expect(library.recordings.isEmpty)
    }

    @Test
    func aDeletionFromAnotherDeviceWins() {
        let recording = Recording(title: "Shared", transcript: "text", duration: 30)
        var deletedRemotely = recording
        deletedRemotely.deletedAt = Date(timeIntervalSince1970: 100)
        deletedRemotely.updatedAt = Date(timeIntervalSince1970: 100)
        var localCopy = recording
        localCopy.updatedAt = Date(timeIntervalSince1970: 200)

        let merged = RecordingMerge.merge(localCopy, deletedRemotely)

        #expect(merged.isDeleted)
        #expect(merged.deletedAt == Date(timeIntervalSince1970: 100))
    }

    private func makeLibrary() async throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: try Scratch().directory,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        return library
    }
}
