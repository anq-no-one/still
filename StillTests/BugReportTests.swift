import CryptoKit
import Foundation
import SwiftData
import Synchronization
import Testing
@testable import Still

struct DebugBundleStoreTests {
    @Test
    func onlyTheNewestBundlesAreKept() throws {
        let scratch = try Scratch()
        let store = DebugBundleStore(directory: scratch.directory.appending(path: "saved"), keeps: 2)

        for index in 1...3 {
            try store.save(Data("zip \(index)".utf8), named: "Still-Debug-\(index).zip")
            Thread.sleep(forTimeInterval: 0.02)
        }

        #expect(store.bundles().map(\.name) == ["Still-Debug-3.zip", "Still-Debug-2.zip"])
    }

    @Test
    func savingABuiltBundleMovesItIntoTheFolder() throws {
        let scratch = try Scratch()
        let built = scratch.directory.appending(path: "Still-Debug-a.zip")
        try Data("PK".utf8).write(to: built)
        let store = DebugBundleStore(directory: scratch.directory.appending(path: "saved"))

        let saved = try store.save(built)

        #expect(!FileManager.default.fileExists(atPath: built.path(percentEncoded: false)))
        #expect(store.bundles().map(\.name) == [saved.lastPathComponent])
    }

    @Test @MainActor
    func anAppStoreBuildDeletesSavedBundles() async throws {
        let scratch = try Scratch()
        let store = DebugBundleStore(directory: scratch.directory.appending(path: "saved"))
        try store.save(Data("PK".utf8), named: "Still-Debug-old.zip")
        let developer = DeveloperDiagnostics(
            directory: scratch.directory.appending(path: "developer"),
            key: SymmetricKey(size: .bits256),
            streams: (DevLogStream(category: "a"), DevLogStream(category: "b")),
            savedBundles: store
        )

        await developer.start(startsMonitors: false) { .appStore }

        #expect(store.bundles().isEmpty)
    }
}

struct ProblemMarkerTests {
    @Test
    func aMarkerKeepsTheMomentInTheLogAndOnDisk() async throws {
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test")
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))
        stream.setEnabled(true)
        let markers = ProblemMarkers(directory: scratch.directory.appending(path: "Markers"), stream: stream)

        let folder = try #require(markers.capture(
            ProblemMarker(reason: .tester, note: "transcript froze", screen: "detail"),
            state: ["sync": ["lastFailure": "zoneNotFound"]]
        ))
        await stream.flush()

        let record = try #require(try stream.records().first { $0.name == "user.marker" })
        #expect(record.fields?["note"] == "transcript froze")
        #expect(markers.all().map(\.note) == ["transcript froze"])
        let threads = try String(contentsOf: folder.appending(path: "threads.txt"), encoding: .utf8)
        let state = try String(contentsOf: folder.appending(path: "state.json"), encoding: .utf8)
        #expect(threads.contains("Thread "))
        #expect(state.contains("zoneNotFound"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "memory.json").path(percentEncoded: false)))
    }

    @Test @MainActor
    func openingTheReportFromAShortcutMarksTheMomentFirst() async throws {
        let scratch = try Scratch()
        let developer = DeveloperDiagnostics(
            directory: scratch.directory,
            key: SymmetricKey(size: .bits256),
            streams: (DevLogStream(category: "a"), DevLogStream(category: "b"))
        )
        let diagnostics = Diagnostics(settings: MemoryDiagnosticsSettings(), sink: SpyDiagnosticsSink(), developer: developer)
        await developer.start(startsMonitors: false) { .testFlight }

        diagnostics.requestProblemReport(from: .shortcut)
        diagnostics.requestProblemReport(from: .button)

        #expect(diagnostics.problemReport?.source == .button)
        #expect(developer.markers?.all().count == 1)
    }

    @Test @MainActor
    func anAppStoreBuildOpensNoReport() async throws {
        let developer = DeveloperDiagnostics(streams: (DevLogStream(category: "a"), DevLogStream(category: "b")))
        let diagnostics = Diagnostics(settings: MemoryDiagnosticsSettings(), sink: SpyDiagnosticsSink(), developer: developer)
        await developer.start(startsMonitors: false) { .appStore }

        diagnostics.requestProblemReport(from: .shake)

        #expect(diagnostics.problemReport == nil)
    }
}

struct BugReportPackingTests {
    private let accountKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

    private func manifest() -> BugReportManifest {
        BugReportManifest(id: UUID(), createdAt: .now, accountID: UUID(), device: "iPhone", fileName: "Still-Debug.zip", bytes: 0, parts: 0, sha256: "")
    }

    @Test
    func aReportComesBackWholeFromItsParts() throws {
        let key = BugReportPacking.key(accountKey: accountKey)
        let zip = Data((0..<2_000_000).map { UInt8($0 % 251) })

        let packed = try BugReportPacking.pack(zip, manifest: manifest(), key: key)
        let opened = try BugReportPacking.manifest(packed.manifest, key: key)

        #expect(packed.parts.count == 3)
        #expect(packed.parts.allSatisfy { $0.count < 1_000_000 })
        #expect(opened.parts == 3)
        #expect(try BugReportPacking.unpack(packed.parts, manifest: opened, key: key) == zip)
    }

    @Test
    func aDeviceFromAnotherLibraryCannotOpenIt() throws {
        let packed = try BugReportPacking.pack(Data("zip".utf8), manifest: manifest(), key: BugReportPacking.key(accountKey: accountKey))
        let otherKey = BugReportPacking.key(accountKey: Data(repeating: 1, count: 32))

        #expect(throws: BugReportError.otherLibrary) {
            try BugReportPacking.manifest(packed.manifest, key: otherKey)
        }
    }

    @Test
    func aPartThatChangedOnTheWayIsRefused() throws {
        let key = BugReportPacking.key(accountKey: accountKey)
        let packed = try BugReportPacking.pack(Data((0..<1_000_000).map { UInt8($0 % 241) }), manifest: manifest(), key: key)
        let opened = try BugReportPacking.manifest(packed.manifest, key: key)
        var parts = packed.parts
        parts.swapAt(0, 1)

        #expect(throws: BugReportError.damaged) {
            try BugReportPacking.unpack(parts, manifest: opened, key: key)
        }
        #expect(throws: BugReportError.missingParts) {
            try BugReportPacking.unpack(Array(packed.parts.prefix(1)), manifest: opened, key: key)
        }
    }
}

@MainActor
struct BugReportCourierTests {
    private let account = (id: UUID(), key: Data(repeating: 9, count: 32))

    @Test
    func aReportSentFromOneDeviceLandsInTheMacsInbox() async throws {
        let scratch = try Scratch()
        let cloud = MemoryBugReportTransport()
        let zip = scratch.directory.appending(path: "Still-Debug-iphone.zip")
        try Data((0..<1_500_000).map { UInt8($0 % 13) }).write(to: zip)
        let phone = BugReportCourier(transport: cloud, settings: MemoryBugReportSettings(), accountKey: { [account] in account }, device: "iPhone", inbox: DebugBundleStore(directory: scratch.directory.appending(path: "phone")), canReceive: false)
        let inbox = DebugBundleStore(directory: scratch.directory.appending(path: "inbox"))
        let mac = BugReportCourier(transport: cloud, settings: MemoryBugReportSettings(), accountKey: { [account] in account }, device: "Mac", inbox: inbox, canReceive: true, receivesByDefault: true)

        await phone.submit(zip)
        await mac.collect()

        #expect(phone.sendState == .sent)
        let received = try #require(inbox.bundles().first)
        #expect(received.name.contains("iPhone"))
        #expect(try Data(contentsOf: received.url) == Data(contentsOf: zip))
        #expect(cloud.isEmpty)
        #expect(mac.received.count == 1)
    }

    @Test
    func aMacThatCollectsReportsKeepsItsOwnWithoutICloud() async throws {
        let scratch = try Scratch()
        let cloud = MemoryBugReportTransport()
        let zip = scratch.directory.appending(path: "Still-Debug-mac.zip")
        try Data("PK".utf8).write(to: zip)
        let inbox = DebugBundleStore(directory: scratch.directory.appending(path: "inbox"))
        let mac = BugReportCourier(transport: cloud, settings: MemoryBugReportSettings(), accountKey: { [account] in account }, device: "Mac", inbox: inbox, canReceive: true, receivesByDefault: true)

        await mac.submit(zip)

        #expect(cloud.isEmpty)
        #expect(inbox.bundles().count == 1)
        guard case .savedHere = mac.sendState else {
            Issue.record("expected the report to be saved on this Mac")
            return
        }
    }

    @Test
    func aReportFromAnotherLibraryStaysInICloud() async throws {
        let scratch = try Scratch()
        let cloud = MemoryBugReportTransport()
        let zip = scratch.directory.appending(path: "Still-Debug-other.zip")
        try Data("PK".utf8).write(to: zip)
        let stranger = BugReportCourier(transport: cloud, settings: MemoryBugReportSettings(), accountKey: { (UUID(), Data(repeating: 3, count: 32)) }, device: "iPad", inbox: DebugBundleStore(directory: scratch.directory.appending(path: "ipad")), canReceive: false)
        let inbox = DebugBundleStore(directory: scratch.directory.appending(path: "inbox"))
        let mac = BugReportCourier(transport: cloud, settings: MemoryBugReportSettings(), accountKey: { [account] in account }, device: "Mac", inbox: inbox, canReceive: true, receivesByDefault: true)

        await stranger.submit(zip)
        await mac.collect()

        #expect(inbox.bundles().isEmpty)
        #expect(!cloud.isEmpty)
        #expect(mac.receiveProblem != nil)
    }

    @Test
    func aMacThatDoesNotCollectLeavesReportsWaiting() async throws {
        let scratch = try Scratch()
        let cloud = MemoryBugReportTransport()
        let zip = scratch.directory.appending(path: "Still-Debug-x.zip")
        try Data("PK".utf8).write(to: zip)
        let phone = BugReportCourier(transport: cloud, settings: MemoryBugReportSettings(), accountKey: { [account] in account }, device: "iPhone", inbox: DebugBundleStore(directory: scratch.directory.appending(path: "phone")), canReceive: false)
        let inbox = DebugBundleStore(directory: scratch.directory.appending(path: "inbox"))
        let otherMac = BugReportCourier(transport: cloud, settings: MemoryBugReportSettings(), accountKey: { [account] in account }, device: "Work Mac", inbox: inbox, canReceive: true, receivesByDefault: false)

        await phone.submit(zip)
        await otherMac.collect()

        #expect(inbox.bundles().isEmpty)
        #expect(!cloud.isEmpty)
    }
}

@MainActor
struct BugReportBundleTests {
    @Test
    func theTestersNoteAndImagesTravelInTheBundle() async throws {
        let scratch = try Scratch()
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: scratch.directory.appending(path: "audio"),
                makeRepository: { key in MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) } },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        let key = SymmetricKey(size: .bits256)
        let log = DevLogStream(category: "test-main")
        let ai = DevLogStream(category: "test-ai")
        log.configure(directory: scratch.directory.appending(path: "logs"), name: "devlog", key: key)
        ai.configure(directory: scratch.directory.appending(path: "logs"), name: "ai-trace", key: key)
        let builder = DebugBundleBuilder(
            library: library,
            journal: DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), key: key),
            developer: DeveloperDiagnostics(),
            context: { [:] },
            log: log,
            aiLog: ai,
            parent: scratch.directory.appending(path: "bundles")
        )

        let folder = try await builder.prepareFolder(
            DebugBundleRequest(
                recordingIDs: [],
                includesAudio: false,
                note: "Speaker names swapped after sync",
                attachments: [BugReportAttachment(name: "attachment-1.png", data: Data([0x89, 0x50, 0x4E, 0x47]))]
            ),
            progress: { _ in }
        )

        #expect(try String(contentsOf: folder.appending(path: "note.txt"), encoding: .utf8) == "Speaker names swapped after sync")
        #expect(try Data(contentsOf: folder.appending(path: "attachments/attachment-1.png")) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}

private final class MemoryBugReportTransport: BugReportTransport, Sendable {
    private let records = Mutex<[UUID: (manifest: Data, parts: [Data])]>([:])

    var isEmpty: Bool {
        records.withLock { $0.isEmpty }
    }

    func send(_ id: UUID, manifest: Data, parts: [Data], progress: @escaping @Sendable (Int) -> Void) async throws {
        records.withLock { $0[id] = (manifest, parts) }
        progress(parts.count)
    }

    func waiting() async throws -> [UUID: Data] {
        records.withLock { $0.mapValues(\.manifest) }
    }

    func parts(of id: UUID, count: Int) async throws -> [Data] {
        records.withLock { $0[id]?.parts ?? [] }
    }

    func remove(_ id: UUID, parts: Int) async throws {
        _ = records.withLock { $0.removeValue(forKey: id) }
    }
}

private final class MemoryBugReportSettings: BugReportSettingsStore, Sendable {
    private let value = Mutex<Bool?>(nil)

    func receives(byDefault: Bool) -> Bool {
        value.withLock { $0 } ?? byDefault
    }

    func setReceives(_ receives: Bool) {
        value.withLock { $0 = receives }
    }
}
