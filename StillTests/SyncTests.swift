import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

struct RecordingMergeTests {
    @Test
    func keepsBothTitlesWhenTwoDevicesDisagree() {
        let base = sample()
        var local = base
        local.title = "Board sync"
        local.updatedAt = Date(timeIntervalSince1970: 200)
        var remote = base
        remote.title = "Board meeting"
        remote.updatedAt = Date(timeIntervalSince1970: 100)

        let merged = RecordingMerge.merge(local, remote)

        #expect(merged.title.contains("Board sync"))
        #expect(merged.title.contains("Board meeting"))
    }

    @Test
    func convergesToTheSameResultFromEitherSide() {
        let base = sample()
        var local = base
        local.title = "B"
        local.note = Note(template: .meeting, userText: "local thought")
        local.updatedAt = Date(timeIntervalSince1970: 200)
        var remote = base
        remote.title = "A"
        remote.note = Note(template: .meeting, userText: "remote thought")
        remote.updatedAt = Date(timeIntervalSince1970: 100)

        let one = RecordingMerge.merge(local, remote)
        let other = RecordingMerge.merge(remote, local)

        #expect(one.title == other.title)
        #expect(one.note?.userText == other.note?.userText)
        #expect(one.note?.userText.contains("local thought") == true)
        #expect(one.note?.userText.contains("remote thought") == true)
    }

    @Test
    func keepsAUserAddedActionAfterTheOtherDeviceRegenerates() {
        let base = sample()
        let mine = NoteItem(text: "Email the summary", sourceSegmentIDs: [], isUserAuthored: true)
        var local = base
        local.note = Note(template: .meeting, actions: [mine])
        local.updatedAt = Date(timeIntervalSince1970: 100)
        var remote = base
        remote.note = Note(
            template: .meeting,
            actions: [NoteItem(text: "Generated action", sourceSegmentIDs: [])]
        )
        remote.updatedAt = Date(timeIntervalSince1970: 200)

        let merged = RecordingMerge.merge(local, remote)

        #expect(merged.note?.actions.contains { $0.id == mine.id } == true)
        #expect(merged.note?.actions.count == 2)
    }

    @Test
    func keepsBothCorrectionsOfOneSegment() {
        var segments = words("Ana .")
        segments[0].correction = "Anna"
        var local = sample()
        local.segments = segments
        local.updatedAt = Date(timeIntervalSince1970: 200)

        var otherSegments = segments
        otherSegments[0].correction = "Hannah"
        var remote = sample()
        remote.segments = otherSegments
        remote.updatedAt = Date(timeIntervalSince1970: 100)

        let merged = RecordingMerge.merge(local, remote)

        #expect(merged.segments[0].correction?.contains("Anna") == true)
        #expect(merged.segments[0].correction?.contains("Hannah") == true)
    }

    private func sample() -> Recording {
        Recording(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Base",
            transcript: "text",
            duration: 60
        )
    }
}

@MainActor
struct SyncEngineTests {
    @Test
    func syncIsOnForANewInstall() throws {
        let suite = "still.sync.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserDefaultsSyncSettings(defaults: defaults).isEnabled())
    }

    @Test
    func sendsNothingWhileSyncIsOff() async throws {
        let transport = SpySyncTransport()
        let engine = try await makeEngine(transport: transport)

        await engine.sync()

        #expect(!engine.isEnabled)
        #expect(transport.pushed.isEmpty)
        #expect(engine.lastFailure == SyncError.disabled.localizedDescription)
    }

    @Test
    func sendsOnlyCiphertext() async throws {
        let transport = SpySyncTransport()
        let library = try await makeLibrary()
        let engine = makeEngine(library: library, transport: transport)
        try library.add(
            Recording(title: "Budget review", transcript: "We agreed to delay hiring", duration: 60, projectAssignedAt: .now)
        )

        engine.enable()
        await engine.sync()

        let changes = try #require(transport.pushed.first)
        #expect(changes.contains { $0.kind == .recording })
        for change in changes {
            let bytes = String(decoding: change.payload ?? Data(), as: UTF8.self)
            #expect(!bytes.contains("Budget review"))
            #expect(!bytes.contains("delay hiring"))
        }
    }

    @Test
    func mergesARemoteChangeIntoTheLocalLibrary() async throws {
        let library = try await makeLibrary()
        let transport = SpySyncTransport()
        let engine = makeEngine(library: library, transport: transport)
        let recording = Recording(title: "Local title", transcript: "text", duration: 60, updatedAt: Date(timeIntervalSince1970: 100))
        try library.add(recording)

        var remote = recording
        remote.title = "Remote title"
        remote.updatedAt = Date(timeIntervalSince1970: 200)
        transport.incoming = [try #require(try library.syncChange(for: remote, deviceID: UUID()))]

        engine.enable()
        await engine.sync()

        let merged = try #require(library.recordings.first)
        #expect(merged.title.contains("Local title"))
        #expect(merged.title.contains("Remote title"))
    }

    @Test
    func ignoresChangesThisDeviceSent() async throws {
        let library = try await makeLibrary()
        let transport = SpySyncTransport()
        let deviceID = UUID()
        let engine = makeEngine(library: library, transport: transport, deviceID: deviceID)
        var recording = Recording(title: "Mine", transcript: "text", duration: 60)
        try library.add(recording)
        recording.title = "Stale copy"
        transport.incoming = [try #require(try library.syncChange(for: recording, deviceID: deviceID))]

        engine.enable()
        await engine.sync()

        #expect(library.recordings.map(\.title) == ["Mine"])
    }

    @Test
    func anUnreachableTransportChangesNothingLocally() async throws {
        let library = try await makeLibrary()
        let transport = SpySyncTransport()
        transport.failure = SyncError.unreachable
        let engine = makeEngine(library: library, transport: transport)
        try library.add(Recording(title: "Kept", transcript: "text", duration: 60))

        engine.enable()
        await engine.sync()

        #expect(engine.lastFailure == SyncError.unreachable.localizedDescription)
        #expect(library.recordings.map(\.title) == ["Kept"])
    }

    @Test
    func anUnconfirmedRecordingSyncsUnderItsSuggestedProject() async throws {
        let transport = SpySyncTransport()
        let library = try await makeLibrary()
        let engine = makeEngine(library: library, transport: transport)
        let project = try library.createProject(named: "Acme", color: .blue)
        let recording = Recording(title: "Suggested", transcript: "text", duration: 60, projectID: project.id)
        try library.add(recording)

        engine.enable()
        await engine.sync()

        let sent = try #require(transport.pushed.flatMap { $0 }.first { $0.id == recording.id })
        #expect(sent.scopeID == project.id)
    }

    @Test
    func confirmingReleasesTheRecordingOnceEvenAfterAnInterruptedSync() async throws {
        let transport = SpySyncTransport()
        let library = try await makeLibrary()
        let engine = makeEngine(library: library, transport: transport)
        let recording = Recording(title: "Standup", transcript: "text", duration: 60)
        try library.add(recording)
        engine.enable()

        try library.confirmProjects(of: [recording.id])
        transport.failure = SyncError.unreachable
        await engine.sync()
        transport.failure = nil
        await engine.sync()

        let sent = transport.pushed.flatMap { $0 }.filter { $0.id == recording.id }
        #expect(sent.count == 1)
        #expect(library.recordings.first?.isProjectConfirmed == true)
    }

    @Test
    func aCorrectedProjectReachesTheCloudUnderTheNewProject() async throws {
        let transport = SpySyncTransport()
        let library = try await makeLibrary()
        let engine = makeEngine(library: library, transport: transport)
        let wrong = try library.createProject(named: "Wrong", color: .red)
        let right = try library.createProject(named: "Right", color: .green)
        let recording = Recording(title: "Review", transcript: "text", duration: 60, projectID: wrong.id)
        try library.add(recording)
        engine.enable()

        await engine.sync()
        #expect(transport.pushed.flatMap { $0 }.first { $0.id == recording.id }?.scopeID == wrong.id)

        try library.assign([recording.id], toProject: right.id)
        await engine.sync()

        let sent = try #require(transport.pushed.flatMap { $0 }.last { $0.id == recording.id })
        #expect(try library.openRecording(from: sent).projectID == right.id)
    }

    private func makeEngine(
        library: Library? = nil,
        transport: SyncTransport,
        deviceID: UUID = UUID()
    ) -> SyncEngine {
        SyncEngine(
            library: library!,
            transport: transport,
            settings: MemorySyncSettings(),
            identity: DeviceIdentity(id: deviceID)
        )
    }

    private func makeEngine(transport: SyncTransport) async throws -> SyncEngine {
        makeEngine(library: try await makeLibrary(), transport: transport)
    }

    private func makeLibrary() async throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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

final class SpySyncTransport: SyncTransport, @unchecked Sendable {
    var incoming: [SyncChange] = []
    var failure: Error?
    private(set) var pushed: [[SyncChange]] = []

    func push(_ changes: [SyncChange]) async throws {
        if let failure { throw failure }
        pushed.append(changes)
    }

    func pull(payloadsFor scopes: Set<UUID>) async throws -> [SyncChange] {
        if let failure { throw failure }
        return incoming
    }
}

final class MemorySyncSettings: SyncSettingsStore, @unchecked Sendable {
    private var enabled = false
    private var syncedAt: Date?

    func isEnabled() -> Bool { enabled }
    func setEnabled(_ value: Bool) { enabled = value }
    func lastSyncedAt() -> Date? { syncedAt }
    func setLastSyncedAt(_ date: Date) { syncedAt = date }
}
