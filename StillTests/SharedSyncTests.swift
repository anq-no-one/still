import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct SharedSyncTests {
    @Test
    func devicesOnOneAppleAccountShareEveryRecordingWithoutAPairingCode() async throws {
        let cloud = MemorySyncCloud()
        let keychain = MemorySharedKeyStore()
        let homeMac = try await SyncedDevice.make(kind: .mac, cloud: cloud, keychain: keychain)
        let workMac = try await SyncedDevice.make(kind: .mac, cloud: cloud, keychain: keychain)
        let phone = try await SyncedDevice.make(kind: .iphone, cloud: cloud, keychain: keychain)

        let standup = Recording(title: "Standup", transcript: "standup", duration: 60)
        try homeMac.library.add(standup)
        let client = try workMac.library.createProject(named: "Client", color: .blue)
        let review = Recording(title: "Review", transcript: "review", duration: 60, projectID: client.id, projectAssignedAt: .now)
        try workMac.library.add(review)

        try await settle([homeMac, workMac, phone])

        for device in [homeMac, workMac, phone] {
            let titles = Set(device.library.storedRecordings.map(\.title))
            #expect(titles == ["Standup", "Review"])
            #expect(device.library.accountID == homeMac.library.accountID)
        }
    }

    @Test
    func aDeviceThatTurnsAProjectOffDoesNotReceiveIt() async throws {
        let cloud = MemorySyncCloud()
        let keychain = MemorySharedKeyStore()
        let phone = try await SyncedDevice.make(kind: .iphone, cloud: cloud, keychain: keychain)
        let mac = try await SyncedDevice.make(kind: .mac, cloud: cloud, keychain: keychain)
        let private_ = try phone.library.createProject(named: "Private", color: .red)
        try phone.library.add(Recording(title: "Doctor", transcript: "doctor", duration: 60, projectID: private_.id, projectAssignedAt: .now))
        try phone.library.add(Recording(title: "Team", transcript: "team", duration: 60))
        mac.library.setProjectSelection(ProjectSelection(mode: .except, scopes: [.project(private_.id)]))

        try await settle([phone, mac])

        #expect(Set(mac.library.storedRecordings.map(\.title)) == ["Team"])
        #expect(mac.transport.receivedPayloads(inScope: private_.id).isEmpty)
    }

    @Test
    func aRecordingStillProcessingWaitsUntilItIsFinished() async throws {
        let cloud = MemorySyncCloud()
        let keychain = MemorySharedKeyStore()
        let mac = try await SyncedDevice.make(kind: .mac, cloud: cloud, keychain: keychain)
        let phone = try await SyncedDevice.make(kind: .iphone, cloud: cloud, keychain: keychain)
        var call = Recording(title: "Call", transcript: "", duration: 60, isProcessing: true)
        try mac.library.add(call)

        try await settle([mac, phone])
        #expect(phone.library.storedRecordings.isEmpty)

        call.isProcessing = false
        call.transcript = "finished"
        call.updatedAt = .now
        try mac.library.save(call)
        try await settle([mac, phone])

        #expect(phone.library.storedRecordings.map(\.transcript) == ["finished"])
    }

    private func settle(_ devices: [SyncedDevice]) async throws {
        for _ in 0..<3 {
            for device in devices {
                await device.engine.sync()
                #expect(device.engine.lastFailure == nil)
            }
        }
    }
}

@MainActor
struct LibraryAudioSyncTests {
    @Test
    func aChunkAddressSurvivesTheIndex() {
        let recordingID = UUID()
        let ids = [
            AudioChunkID(recordingID: recordingID, track: .microphone, part: .manifest),
            AudioChunkID(recordingID: recordingID, track: .system, part: .chunk(41)),
        ]
        var index = AudioChunkIndex()
        index.add(Dictionary(uniqueKeysWithValues: ids.map { ($0, "digest-\(AudioChunkIndex.key(for: $0))") }))

        let decoded = try? JSONDecoder().decode(AudioChunkIndex.self, from: JSONEncoder().encode(index))

        #expect(decoded?.digests(forRecording: recordingID) == index.digests(forRecording: recordingID))
        #expect(Set(index.digests(forRecording: recordingID).keys) == Set(ids))
        #expect(AudioChunkIndex.recordName(for: ids[1]) == "audio-\(recordingID.uuidString)-system-c41")
    }

    @Test
    func audioIsUploadedOnceAndThenLeftAlone() async throws {
        let device = try await SyncedDevice.make(kind: .mac, cloud: MemorySyncCloud(), keychain: MemorySharedKeyStore())
        let recording = Recording(title: "Call", transcript: "call", duration: 10)
        try device.library.add(recording)
        try device.writeAudio(for: recording.id, seconds: 10)
        let transport = FakeChunkTransport()
        let ledger = MemoryAudioSyncLedger()
        let audio = device.audioSync(transport: transport, ledger: ledger)

        await audio.run()
        let firstUploads = transport.uploads
        await audio.run()
        await audio.run()

        #expect(firstUploads > 0)
        #expect(ledger.isSettled(recording.id))
        #expect(transport.uploads == firstUploads)
    }

    @Test
    func aRecordingWhoseAudioHasNotArrivedIsAskedAboutAgain() async throws {
        let device = try await SyncedDevice.make(kind: .mac, cloud: MemorySyncCloud(), keychain: MemorySharedKeyStore())
        let recording = Recording(title: "Remote", transcript: "remote", duration: 10)
        try device.library.add(recording)
        let ledger = MemoryAudioSyncLedger()

        await device.audioSync(transport: FakeChunkTransport(), ledger: ledger).run()

        #expect(!ledger.isSettled(recording.id))
    }
}

final class MemorySharedKeyStore: SharedKeyStore, @unchecked Sendable {
    private var keys: SharedAccountKeys?

    func load() throws -> SharedAccountKeys? { keys }
    func save(_ keys: SharedAccountKeys) throws { self.keys = keys }
}

final class MemoryAudioSyncLedger: AudioSyncLedger, @unchecked Sendable {
    private var settled: Set<UUID> = []

    func isSettled(_ recordingID: UUID) -> Bool { settled.contains(recordingID) }
    func settle(_ recordingID: UUID) { settled.insert(recordingID) }
}

@MainActor
private final class SyncedDevice {
    let library: Library
    let engine: SyncEngine
    let transport: MemorySyncTransport
    let scratch: Scratch

    private init(library: Library, engine: SyncEngine, transport: MemorySyncTransport, scratch: Scratch) {
        self.library = library
        self.engine = engine
        self.transport = transport
        self.scratch = scratch
    }

    static func make(kind: DeviceKind, cloud: MemorySyncCloud, keychain: SharedKeyStore) async throws -> SyncedDevice {
        let scratch = try Scratch()
        let container = try ModelContainer(
            for: EncryptedRecording.self, EncryptedProject.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: scratch.directory,
                settingsFile: scratch.directory.appending(path: "Library.settings"),
                keysFile: scratch.directory.appending(path: "Library.keys"),
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } },
                makeProjectRepository: { key in
                    MainActor.assumeIsolated { EncryptedProjectRepository(context: context, key: key) }
                }
            )
        )
        await library.unlock()
        let transport = MemorySyncTransport(cloud: cloud)
        let engine = SyncEngine(
            library: library,
            transport: transport,
            settings: MemorySyncSettings(),
            identity: DeviceIdentity(kind: kind),
            sharedKeys: keychain
        )
        engine.enable()
        return SyncedDevice(library: library, engine: engine, transport: transport, scratch: scratch)
    }

    func writeAudio(for id: UUID, seconds: Int) throws {
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: id, track: .microphone, in: scratch.directory),
            cipher: try #require(library.audioSealing(forRecording: id)).local,
            format: .transcription
        )
        try writer.append(Data(repeating: 7, count: seconds * AudioFormat.transcription.bytesPerSecond))
        try writer.finish()
    }

    func audioSync(transport: AudioChunkTransport, ledger: AudioSyncLedger) -> LibraryAudioSync {
        LibraryAudioSync(
            library: library,
            chunks: AudioChunkSync(
                audioRoot: scratch.directory,
                transport: transport,
                keepsAudio: { [library] in library.keepsAudio(forRecording: $0) },
                sealing: { [library] in library.audioSealing(forRecording: $0) }
            ),
            ledger: ledger
        )
    }
}
