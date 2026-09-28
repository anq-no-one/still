import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct DiagnosticJournalTests {
    private let key = SymmetricKey(size: .bits256)

    @Test
    func theJournalIsUnreadableWithoutThisDevicesKey() throws {
        let scratch = try Scratch()
        let url = scratch.directory.appending(path: "journal.jsonl")
        DiagnosticJournal(fileURL: url, key: key).fail(.libraryUnlockFailed)

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("libraryUnlockFailed"))
        #expect(try DiagnosticJournal(fileURL: url, key: key).entries().count == 1)
        #expect(try DiagnosticJournal(fileURL: url, key: SymmetricKey(size: .bits256)).entries().isEmpty)
    }
    @Test
    func aFailedUnlockWritesOneEventWithItsBreadcrumbs() async throws {
        let scratch = try Scratch()
        let journal = DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), key: key, appVersion: "1.2")
        journal.note(.appLaunched)
        let source = FakeDeviceKeySource()
        source.deviceKeyError = NSError(
            domain: "com.apple.LocalAuthentication",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Meeting with Dana Kim", NSFilePathErrorKey: "/Users/dana/secret.caf"]
        )
        let library = try makeLibrary(source: source, audioRoot: scratch.directory, journal: journal)

        await library.unlock()

        let entries = try journal.entries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.code == .libraryUnlockFailed)
        #expect(entry.appVersion == "1.2")
        #expect(entry.errorCode == "com.apple.LocalAuthentication#-2")
        #expect(entry.correlationID != nil)
        #expect(entry.breadcrumbs.map(\.code) == [.appLaunched, .libraryUnlockStarted])

        let raw = try String(contentsOf: journal.fileURL, encoding: .utf8)
        #expect(!raw.contains("Dana"))
        #expect(!raw.contains("/Users"))
    }

    @Test
    func keepsOnlyTheLastHundredBreadcrumbs() throws {
        let scratch = try Scratch()
        let journal = DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), key: key)
        for _ in 0..<150 { journal.note(.recordingStarted) }
        journal.note(.recordingSaved)

        journal.fail(.exportFailed)

        let entry = try #require(try journal.entries().first)
        #expect(entry.breadcrumbs.count == DiagnosticJournal.breadcrumbLimit)
        #expect(entry.breadcrumbs.last?.code == .recordingSaved)
    }

    @Test
    func exportsEveryEntryAsPlainTextReadingInSmallChunks() throws {
        let scratch = try Scratch()
        let journal = DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), key: key, appVersion: "2.0")
        for _ in 0..<40 {
            journal.note(.syncFailed)
            journal.fail(.syncFailed, error: CocoaError(.fileReadNoPermission))
        }

        var streamed = 0
        try journal.lines.forEach(in: journal.fileURL, chunkSize: 17) { _ in streamed += 1 }
        #expect(streamed == 40)

        let destination = scratch.directory.appending(path: "export.txt")
        try journal.export(to: destination)
        let text = try String(contentsOf: destination, encoding: .utf8)

        #expect(text.hasPrefix("Still diagnostic journal\n"))
        #expect(text.components(separatedBy: "syncFailed version=2.0 error=NSCocoaErrorDomain#257").count - 1 == 40)
        #expect(!text.contains("{"))
    }

    @Test
    func dropsEntriesOlderThanNinetyDays() throws {
        let scratch = try Scratch()
        var clock = Date(timeIntervalSince1970: 0)
        let journal = DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), key: key, now: { clock })
        journal.fail(.recordingFailed)
        clock += DiagnosticJournal.retention - 60
        journal.fail(.exportFailed)
        clock += 120

        try journal.removeExpired()

        #expect(try journal.entries().map(\.code) == [.exportFailed])
    }

    @Test
    func aJournalThatCannotBeWrittenSaysSoWithoutLoggingItself() throws {
        let scratch = try Scratch()
        let blocker = scratch.directory.appending(path: "not-a-folder")
        try Data("x".utf8).write(to: blocker)
        let journal = DiagnosticJournal(fileURL: blocker.appending(path: "journal.jsonl"), key: key)

        journal.fail(.recordingFailed)
        journal.fail(.recordingFailed)

        #expect(journal.writeProblem?.isEmpty == false)
        #expect(try journal.entries().isEmpty)
    }

    @Test
    func aRecordSaveAndExportJourneyAppearsInOrderWithoutAnyTypedText() async throws {
        let scratch = try Scratch()
        let journal = DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), key: key)
        let library = try makeLibrary(source: FakeDeviceKeySource(), audioRoot: scratch.directory, journal: journal)
        await library.unlock()
        let session = FakeTranscriptionSession()
        let transcriber = StubOfflineTranscriber()
        transcriber.result = "Secret budget for Dana"
        let coordinator = RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { session },
            makeFinalTranscription: {
                FinalTranscription(transcriber: transcriber, windowSeconds: 3_600)
            }
        )

        await coordinator.start()
        await coordinator.stopAndSave()
        await coordinator.waitForBackgroundProcessing()
        var recording = try #require(library.recordings.first)
        recording.title = "Acquisition of Contoso"
        _ = try library.archive(recording, tracks: library.tracks(forRecording: recording.id))
        try library.confirmProjects(of: [recording.id])

        let entries = try journal.entries()
        #expect(entries.map(\.code) == [.recordingStarted, .recordingSaved, .exportFinished, .projectConfirmed])
        #expect(Set(entries.compactMap(\.correlationID)) == [recording.id])

        let export = scratch.directory.appending(path: "journal.txt")
        try journal.export(to: export)
        let text = try String(contentsOf: export, encoding: .utf8)
        for secret in ["Secret", "budget", "Dana", "Contoso", scratch.directory.path(percentEncoded: false)] {
            #expect(!text.contains(secret))
        }
    }

    private func makeLibrary(
        source: FakeDeviceKeySource,
        audioRoot: URL,
        journal: DiagnosticJournal
    ) throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        return Library(
            keyRing: LibraryKeyRing(source: source),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { key in
                    MainActor.assumeIsolated { WritingRecorder(root: audioRoot, cipher: LibraryCipher(key: key)) }
                }
            ),
            journal: journal
        )
    }
}
