import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct DiagnosticJournalTests {
    @Test
    func aFailedUnlockWritesOneEventWithItsBreadcrumbs() async throws {
        let scratch = try Scratch()
        let journal = DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), appVersion: "1.2")
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
        let journal = DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"))
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
        let journal = DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), appVersion: "2.0")
        for _ in 0..<40 {
            journal.note(.syncFailed)
            journal.fail(.syncFailed, error: CocoaError(.fileReadNoPermission))
        }

        var streamed = 0
        try JournalLines.forEach(in: journal.fileURL, chunkSize: 17) { _ in streamed += 1 }
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
        let journal = DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), now: { clock })
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
        let journal = DiagnosticJournal(fileURL: blocker.appending(path: "journal.jsonl"))

        journal.fail(.recordingFailed)
        journal.fail(.recordingFailed)

        #expect(journal.writeProblem?.isEmpty == false)
        #expect(try journal.entries().isEmpty)
    }

    private func makeLibrary(source: FakeDeviceKeySource, audioRoot: URL, journal: DiagnosticJournal) throws -> Library {
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
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            ),
            journal: journal
        )
    }
}
