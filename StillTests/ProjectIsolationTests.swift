import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct ProjectIsolationTests {
    @Test
    func anExcludedMacReceivesNothingOfAProject() async throws {
        let trio = try await Trio.make()

        let roadmap = try trio.phone.record("Roadmap review", in: trio.acme)
        let payroll = try trio.phone.record("Payroll sync", in: trio.side)
        try await trio.settle()

        #expect(Set(trio.phone.library.recordings.map(\.id)) == [roadmap.id, payroll.id])
        #expect(trio.workMac.library.recordings.map(\.id) == [roadmap.id])
        #expect(trio.sideMac.library.recordings.map(\.id) == [payroll.id])

        #expect(trio.sideMac.transport.receivedPayloads(inScope: trio.acme).isEmpty)
        #expect(trio.sideMac.library.scopeKey(for: trio.acme) == nil)
        #expect(!trio.sideMac.library.storedRecordings.contains { $0.id == roadmap.id })
        #expect(LibrarySearch.results(for: "Roadmap", in: trio.sideMac.library.storedRecordings).isEmpty)
        #expect(try trio.sideMac.meetings.search("Roadmap").isEmpty)
        #expect(try trio.sideMac.meetings.meetings().allSatisfy { $0.id != roadmap.id })
        #expect(try trio.sideMac.meetings.markdown(forMeeting: roadmap.id) == nil)
        #expect(trio.sideMac.library.storage(of: .project(trio.acme)) == .notStored)

        #expect(Set(try trio.workMac.meetings.search("Roadmap").map(\.meetingID)) == [roadmap.id])
        #expect(trio.workMac.transport.receivedPayloads(inScope: trio.side).isEmpty)
        #expect(trio.workMac.library.storage(of: .project(trio.acme)) == .stored)
        #expect(trio.phone.library.storage(of: .project(trio.side)) == .stored)
        #expect(trio.sideMac.library.projects.map(\.name) == ["Acme", "Side job"])
    }

    @Test
    func bothScreensShowTheSameCodeBeforeJoining() async throws {
        let phone = try await Device.make(kind: .iphone)
        let cloud = phone.cloud
        let mac = try await Device.make(kind: .mac, cloud: cloud)

        await mac.engine.sync()
        await phone.engine.sync()
        await mac.engine.sync()

        let request = try #require(phone.engine.joinRequests.first)
        #expect(request.device.kind == .mac)
        #expect(mac.engine.joinTargets.map(\.code) == [request.code])
        #expect(mac.engine.invitation == nil)

        await phone.engine.approve(request)
        await mac.engine.sync()

        #expect(mac.engine.invitation?.code == request.code)
        #expect(mac.engine.invitation?.from == .iphone)
        #expect(mac.library.accountID != phone.library.accountID)

        await mac.engine.acceptInvitation()

        #expect(mac.library.accountID == phone.library.accountID)
        #expect(mac.engine.invitation == nil)
        #expect(phone.engine.joinRequests.isEmpty)
    }

    @Test
    func deselectingAProjectPurgesItsLocalCopiesAndKeyOnly() async throws {
        let trio = try await Trio.make()
        let roadmap = try trio.phone.record("Roadmap review", in: trio.acme)
        try await trio.settle()
        let audio = try trio.workMac.writeAudio(for: roadmap.id)

        trio.workMac.library.setProjectSelection(ProjectSelection(mode: .only, scopes: []))
        #expect(trio.workMac.library.recordings.isEmpty)
        try await trio.settle()

        #expect(trio.workMac.library.storedRecordings.isEmpty)
        #expect(trio.workMac.library.scopeKey(for: trio.acme) == nil)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(try trio.workMac.meetings.search("Roadmap").isEmpty)
        #expect(trio.workMac.library.storage(of: .project(trio.acme)) == .notStored)
        #expect(trio.phone.library.recordings.map(\.id) == [roadmap.id])
        #expect(trio.phone.library.recordings.first?.isDeleted == false)
    }

    @Test
    func reselectingWaitsForAnotherDeviceAndThenRestores() async throws {
        let trio = try await Trio.make()
        let roadmap = try trio.phone.record("Roadmap review", in: trio.acme)
        try await trio.settle()
        trio.workMac.library.setProjectSelection(ProjectSelection(mode: .only, scopes: []))
        try await trio.settle()

        trio.workMac.library.setProjectSelection(ProjectSelection(mode: .only, scopes: [.project(trio.acme)]))
        #expect(trio.workMac.library.storage(of: .project(trio.acme)) == .waitingForKey)

        await trio.workMac.engine.sync()
        #expect(trio.workMac.library.storage(of: .project(trio.acme)) == .waitingForKey)
        #expect(trio.workMac.library.recordings.isEmpty)

        await trio.phone.engine.sync()
        await trio.workMac.engine.sync()

        #expect(trio.workMac.library.storage(of: .project(trio.acme)) == .stored)
        #expect(trio.workMac.library.recordings.map(\.id) == [roadmap.id])
    }

    @Test
    func aProjectLeavesAMacOnlyAfterAnotherDeviceHasEveryCopy() async throws {
        let trio = try await Trio.make()
        let standup = try trio.workMac.record("Standup notes", in: trio.acme)

        trio.cloud.failPushesAfter = 0
        trio.workMac.library.setProjectSelection(ProjectSelection(mode: .only, scopes: []))
        await trio.workMac.engine.sync()

        #expect(trio.workMac.engine.lastFailure != nil)
        #expect(trio.workMac.library.storage(of: .project(trio.acme)) == .leaving)
        #expect(trio.workMac.library.storedRecordings.map(\.id) == [standup.id])

        trio.cloud.failPushesAfter = 1
        await trio.workMac.engine.sync()
        trio.cloud.failPushesAfter = nil
        try await trio.settle()

        #expect(trio.phone.library.recordings.map(\.id) == [standup.id])
        #expect(trio.cloud.records(ofKind: .recording).count == 1)
        #expect(trio.workMac.library.storedRecordings.isEmpty)
        #expect(trio.workMac.library.scopeKey(for: trio.acme) == nil)
        #expect(trio.workMac.library.storage(of: .project(trio.acme)) == .notStored)
    }

    @Test
    func aLoneHolderNeverDropsItsOnlyCopy() async throws {
        let mac = try await Device.make(kind: .mac)
        let project = try mac.library.createProject(named: "Solo", color: .blue)
        let memo = try mac.record("Solo memo", in: project.id)

        mac.library.setProjectSelection(ProjectSelection(mode: .only, scopes: []))
        await mac.engine.sync()
        await mac.engine.sync()

        #expect(mac.library.storedRecordings.map(\.id) == [memo.id])
        #expect(mac.library.scopeKey(for: project.id) != nil)
        #expect(mac.library.storage(of: .project(project.id)) == .leaving)
    }

    @Test
    func movingARecordingReSealsItUnderTheNewProject() async throws {
        let trio = try await Trio.make()
        let roadmap = try trio.phone.record("Roadmap review", in: trio.acme)
        try await trio.settle()
        let acmeKey = try #require(trio.phone.library.scopeKey(for: trio.acme))

        try trio.phone.library.assign([roadmap.id], toProject: trio.side)
        try await trio.settle()

        let stored = try #require(trio.cloud.records(ofKind: .recording).first)
        #expect(trio.cloud.records(ofKind: .recording).count == 1)
        #expect(stored.scopeID == trio.side)
        #expect(throws: LibraryCipherError.unreadable) {
            try LibraryCipher(key: acmeKey).open(stored.payload ?? Data())
        }
        #expect(trio.workMac.library.storedRecordings.isEmpty)
        #expect(trio.sideMac.library.recordings.map(\.id) == [roadmap.id])
    }

    @Test
    func aGrantFromAnUntrustedDeviceIsIgnored() async throws {
        let trio = try await Trio.make(settling: false)
        let intruder = DeviceIdentity()
        let target = try #require(trio.cloud.device(trio.workMac.engine.deviceID))
        let forged = SymmetricKey(size: .bits256)
        trio.cloud.store(
            SyncChange(
                id: KeyGrant.id(recipient: target.id, subject: trio.acme),
                kind: .grant,
                updatedAt: .now,
                deviceID: intruder.id,
                scopeID: trio.acme,
                recipientID: target.id,
                payload: try KeyGrant.seal(forged.rawBytes, subject: trio.acme, to: target, from: intruder)
            )
        )

        await trio.workMac.engine.sync()

        #expect(trio.workMac.library.scopeKey(for: trio.acme) == nil)
        #expect(trio.workMac.library.storage(of: .project(trio.acme)) == .waitingForKey)
    }
}

struct KeyGrantTests {
    private let sender = DeviceIdentity()
    private let recipient = DeviceIdentity()
    private let scope = UUID()

    @Test
    func theRecipientOpensWhatTheSenderSealed() throws {
        let secret = SymmetricKey(size: .bits256).rawBytes
        let sealed = try KeyGrant.seal(secret, subject: scope, to: record(of: recipient), from: sender)

        let opened = try KeyGrant.open(sealed, subject: scope, as: recipient)

        #expect(opened.secret == secret)
        #expect(opened.sender == sender.publicKey)
        #expect(!sealed.base64EncodedString().contains(secret.base64EncodedString()))
    }

    @Test
    func aTamperedGrantIsRejected() throws {
        var sealed = try KeyGrant.seal(Data(repeating: 1, count: 32), subject: scope, to: record(of: recipient), from: sender)
        let index = sealed.count - 20
        sealed[index] = sealed[index] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")

        #expect(throws: (any Error).self) {
            try KeyGrant.open(sealed, subject: scope, as: recipient)
        }
    }

    @Test
    func aGrantOpensOnlyForItsRecipientAndSubject() throws {
        let sealed = try KeyGrant.seal(Data(repeating: 1, count: 32), subject: scope, to: record(of: recipient), from: sender)

        #expect(throws: (any Error).self) {
            try KeyGrant.open(sealed, subject: scope, as: DeviceIdentity())
        }
        #expect(throws: (any Error).self) {
            try KeyGrant.open(sealed, subject: UUID(), as: recipient)
        }
        #expect(throws: (any Error).self) {
            try KeyGrant.open(sealed, subject: nil, as: recipient)
        }
    }

    @Test
    func bothSidesDeriveTheSameCode() {
        let one = VerificationCode.between(sender.publicKey, recipient.publicKey)

        #expect(one == VerificationCode.between(recipient.publicKey, sender.publicKey))
        #expect(one != VerificationCode.between(sender.publicKey, DeviceIdentity().publicKey))
        #expect(one.count == 11)
    }

    private func record(of identity: DeviceIdentity) -> DeviceRecord {
        DeviceRecord(
            id: identity.id,
            kind: .mac,
            publicKey: identity.publicKey,
            accountID: UUID(),
            accountCreatedAt: .now,
            requestedScopes: [],
            heldScopes: []
        )
    }
}

@MainActor
private struct Trio {
    let cloud: MemorySyncCloud
    let phone: Device
    let workMac: Device
    let sideMac: Device
    let acme: UUID
    let side: UUID

    static func make(settling: Bool = true) async throws -> Trio {
        let phone = try await Device.make(kind: .iphone)
        let workMac = try await Device.make(kind: .mac, cloud: phone.cloud)
        let sideMac = try await Device.make(kind: .mac, cloud: phone.cloud)
        let acme = try phone.library.createProject(named: "Acme", color: .blue).id
        let side = try phone.library.createProject(named: "Side job", color: .green).id
        workMac.library.setProjectSelection(ProjectSelection(mode: .only, scopes: [.project(acme)]))
        sideMac.library.setProjectSelection(ProjectSelection(mode: .only, scopes: [.project(side)]))

        for device in [workMac, sideMac, phone] {
            await device.engine.sync()
        }
        for request in phone.engine.joinRequests {
            await phone.engine.approve(request)
        }
        for mac in [workMac, sideMac] {
            await mac.engine.sync()
            await mac.engine.acceptInvitation()
        }

        let trio = Trio(cloud: phone.cloud, phone: phone, workMac: workMac, sideMac: sideMac, acme: acme, side: side)
        if settling {
            try await trio.settle()
        }
        return trio
    }

    func settle() async throws {
        for _ in 0..<3 {
            for device in [phone, workMac, sideMac] {
                await device.engine.sync()
                #expect(device.engine.lastFailure == nil)
            }
        }
    }
}

@MainActor
private final class Device {
    let library: Library
    let engine: SyncEngine
    let transport: MemorySyncTransport
    let meetings: LibraryMeetingSource
    let scratch: Scratch

    var cloud: MemorySyncCloud {
        transport.cloud
    }

    private init(library: Library, engine: SyncEngine, transport: MemorySyncTransport, scratch: Scratch) {
        self.library = library
        self.engine = engine
        self.transport = transport
        self.scratch = scratch
        meetings = LibraryMeetingSource(library: library)
    }

    static func make(kind: DeviceKind, cloud: MemorySyncCloud = MemorySyncCloud()) async throws -> Device {
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
            identity: DeviceIdentity(kind: kind)
        )
        engine.enable()
        return Device(library: library, engine: engine, transport: transport, scratch: scratch)
    }

    func record(_ title: String, in project: UUID) throws -> Recording {
        let recording = Recording(
            title: title,
            transcript: title,
            duration: 60,
            projectID: project,
            projectAssignedAt: .now
        )
        try library.add(recording)
        return recording
    }

    func writeAudio(for id: UUID) throws -> URL {
        let directory = AudioChunkStore.directory(forRecording: id, in: scratch.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("sealed".utf8).write(to: directory.appending(path: "chunk"))
        return directory
    }
}

final class MemorySyncCloud: @unchecked Sendable {
    struct Interrupted: LocalizedError {
        var errorDescription: String? { "The connection dropped." }
    }

    var failPushesAfter: Int?
    private var stored: [String: SyncChange] = [:]

    func push(_ changes: [SyncChange]) throws {
        for (index, change) in changes.enumerated() {
            if let failPushesAfter, index >= failPushesAfter { throw Interrupted() }
            store(change)
        }
    }

    func store(_ change: SyncChange) {
        stored[change.kind.rawValue + "-" + change.id.uuidString] = change
    }

    func all() -> [SyncChange] {
        stored.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    func records(ofKind kind: SyncChange.Kind) -> [SyncChange] {
        all().filter { $0.kind == kind }
    }

    func device(_ id: UUID) -> DeviceRecord? {
        stored["device-" + id.uuidString]?.payload.flatMap { try? JSONDecoder().decode(DeviceRecord.self, from: $0) }
    }
}

final class MemorySyncTransport: SyncTransport, @unchecked Sendable {
    let cloud: MemorySyncCloud
    private(set) var received: [SyncChange] = []

    init(cloud: MemorySyncCloud) {
        self.cloud = cloud
    }

    func push(_ changes: [SyncChange]) async throws {
        try cloud.push(changes)
    }

    func pull(payloadsFor scopes: Set<UUID>) async throws -> [SyncChange] {
        let changes = cloud.all().map { change in
            guard change.kind == .recording, !(change.scopeID.map(scopes.contains) ?? false) else { return change }
            var withheld = change
            withheld.payload = nil
            return withheld
        }
        received += changes.filter { $0.payload != nil }
        return changes
    }

    func receivedPayloads(inScope scope: UUID) -> [SyncChange] {
        received.filter { $0.kind == .recording && $0.scopeID == scope }
    }
}
