import CloudKit
import Foundation
import OSLog
import Synchronization

struct CloudKitSyncTransport: SyncTransport {
    static let recordType = "StillSyncChange"
    static let zoneID = CKRecordZone.ID(zoneName: "Recordings")
    private static let log = Logger(subsystem: "com.andrii.still", category: "sync")

    private let container: @Sendable () -> CKContainer?

    init(container: @escaping @Sendable () -> CKContainer? = { isProvisioned ? CKContainer.default() : nil }) {
        self.container = container
    }

    static var isProvisioned: Bool {
        #if os(macOS)
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        return hasCloudKitIdentity(
            profile: contents.appending(path: "embedded.provisionprofile"),
            storeReceipt: contents.appending(path: "_MASReceipt/receipt")
        )
        #else
        return hasCloudKitIdentity(
            profile: Bundle.main.bundleURL.appending(path: "embedded.mobileprovision"),
            storeReceipt: nil
        )
        #endif
    }

    static func hasCloudKitIdentity(profile: URL, storeReceipt: URL?) -> Bool {
        let files = FileManager.default
        if files.fileExists(atPath: profile.path) {
            return true
        }
        if let storeReceipt, files.fileExists(atPath: storeReceipt.path) {
            return true
        }
        return false
    }

    func push(_ changes: [SyncChange]) async throws {
        try await reachingCloudKit { database in
            let ids = changes.map(Self.recordID(for:))
            let existing = try await database.records(for: ids, desiredKeys: [])
            let records = zip(changes, ids).map { change, id -> CKRecord in
                let record = (try? existing[id]?.get()) ?? CKRecord(recordType: Self.recordType, recordID: id)
                record["kind"] = change.kind.rawValue as NSString
                record["updatedAt"] = change.updatedAt as NSDate
                record["deviceID"] = change.deviceID.uuidString as NSString
                record["scopeID"] = change.scopeID?.uuidString as NSString?
                record["recipientID"] = change.recipientID?.uuidString as NSString?
                record["payload"] = (change.payload ?? Data()) as NSData
                return record
            }

            _ = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
        }
    }

    func pull(payloadsFor scopes: Set<UUID>) async throws -> [SyncChange] {
        try await reachingCloudKit { database in
            var changes: [SyncChange] = []
            var token: CKServerChangeToken?
            var moreComing = true

            while moreComing {
                let batch = try await database.recordZoneChanges(
                    inZoneWith: Self.zoneID,
                    since: token,
                    desiredKeys: Self.headerKeys
                )
                changes += batch.modificationResultsByID.values.compactMap { result in
                    (try? result.get()).flatMap { Self.change(from: $0.record) }
                }
                token = batch.changeToken
                moreComing = batch.moreComing
            }

            let wanted = changes.filter {
                ($0.kind != .recording && $0.kind != .vocabulary) || $0.scopeID.map(scopes.contains) == true
            }
            var payloads: [CKRecord.ID: Data] = [:]
            for start in stride(from: 0, to: wanted.count, by: Self.fetchBatchSize) {
                let ids = wanted[start..<min(start + Self.fetchBatchSize, wanted.count)].map(Self.recordID(for:))
                for (id, result) in try await database.records(for: ids, desiredKeys: ["payload"]) {
                    payloads[id] = (try? result.get())?["payload"] as? Data
                }
            }

            return changes
                .map { change in
                    var change = change
                    change.payload = payloads[Self.recordID(for: change)]
                    return change
                }
                .sorted { $0.updatedAt < $1.updatedAt }
        }
    }

    private func reachingCloudKit<Result>(_ work: (CKDatabase) async throws -> Result) async throws -> Result {
        guard let container = container() else { throw SyncError.unreachable }
        let database = container.privateCloudDatabase

        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
            return try await work(database)
        } catch {
            Self.log.error("CloudKit failed: \(error, privacy: .public)")
            throw SyncError.unreachable
        }
    }

    private static let headerKeys: [CKRecord.FieldKey] = ["kind", "updatedAt", "deviceID", "scopeID", "recipientID"]
    private static let fetchBatchSize = 200

    static func recordName(for change: SyncChange) -> String {
        switch change.kind {
        case .recording: change.id.uuidString
        default: change.kind.rawValue + "-" + change.id.uuidString
        }
    }

    private static func recordID(for change: SyncChange) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(for: change), zoneID: zoneID)
    }

    private static func change(from record: CKRecord) -> SyncChange? {
        let kind = (record["kind"] as? String).flatMap(SyncChange.Kind.init(rawValue:)) ?? .recording
        let name = record.recordID.recordName
        let prefix = kind.rawValue + "-"
        let idText = kind != .recording && name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name

        guard let id = UUID(uuidString: idText),
              let updatedAt = record["updatedAt"] as? Date,
              let deviceID = (record["deviceID"] as? String).flatMap(UUID.init(uuidString:))
        else { return nil }

        return SyncChange(
            id: id,
            kind: kind,
            updatedAt: updatedAt,
            deviceID: deviceID,
            scopeID: (record["scopeID"] as? String).flatMap(UUID.init(uuidString:)),
            recipientID: (record["recipientID"] as? String).flatMap(UUID.init(uuidString:))
        )
    }
}

/// Audio lives in its own zone so the record pull never walks thousands of
/// chunks. It reuses the record type and fields already deployed to the
/// production schema, because TestFlight and App Store builds cannot add new
/// ones. Each recording keeps one index record of chunk digests, so an
/// inventory is a single fetch instead of a query that would need an index.
struct CloudKitAudioChunkTransport: AudioChunkTransport {
    static let zoneID = CKRecordZone.ID(zoneName: "Audio")
    private static let zoneReady = Mutex(false)
    private static let log = Logger(subsystem: "com.andrii.still", category: "sync")

    private let container: @Sendable () -> CKContainer?
    private let deviceID: UUID

    init(
        deviceID: UUID,
        container: @escaping @Sendable () -> CKContainer? = { CloudKitSyncTransport.isProvisioned ? CKContainer.default() : nil }
    ) {
        self.deviceID = deviceID
        self.container = container
    }

    func upload(_ payload: AudioChunkPayload, digest: String) async throws {
        try await reachingCloudKit { database in
            let record = CKRecord(recordType: CloudKitSyncTransport.recordType, recordID: Self.recordID(AudioChunkIndex.recordName(for: payload.id)))
            fill(record, payload: payload.sealed)
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        }
    }

    func commit(_ digests: [AudioChunkID: String], forRecording id: UUID) async throws {
        guard !digests.isEmpty else { return }
        try await reachingCloudKit { database in
            let recordID = Self.recordID(AudioChunkIndex.indexRecordName(forRecording: id))
            let existing = try? await database.record(for: recordID)
            var index = (existing?["payload"] as? Data).flatMap { try? JSONDecoder().decode(AudioChunkIndex.self, from: $0) }
                ?? AudioChunkIndex()
            index.add(digests)
            let record = existing ?? CKRecord(recordType: CloudKitSyncTransport.recordType, recordID: recordID)
            fill(record, payload: try JSONEncoder().encode(index))
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        }
    }

    func inventory(forRecording id: UUID) async throws -> [AudioChunkID: String] {
        try await reachingCloudKit { database in
            let recordID = Self.recordID(AudioChunkIndex.indexRecordName(forRecording: id))
            let result = try await database.records(for: [recordID], desiredKeys: ["payload"])
            guard let record = try? result[recordID]?.get(),
                  let data = record["payload"] as? Data,
                  let index = try? JSONDecoder().decode(AudioChunkIndex.self, from: data)
            else { return [:] }
            return index.digests(forRecording: id)
        }
    }

    func download(_ id: AudioChunkID) async throws -> AudioChunkPayload {
        try await reachingCloudKit { database in
            let record = try await database.record(for: Self.recordID(AudioChunkIndex.recordName(for: id)))
            guard let sealed = record["payload"] as? Data else { throw SyncError.unreachable }
            return AudioChunkPayload(id: id, sealed: sealed)
        }
    }

    private func fill(_ record: CKRecord, payload: Data) {
        record["kind"] = "audio" as NSString
        record["updatedAt"] = Date() as NSDate
        record["deviceID"] = deviceID.uuidString as NSString
        record["payload"] = payload as NSData
    }

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func reachingCloudKit<Result>(_ work: (CKDatabase) async throws -> Result) async throws -> Result {
        guard let container = container() else { throw SyncError.unreachable }
        let database = container.privateCloudDatabase

        do {
            if !Self.zoneReady.withLock({ $0 }) {
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
                Self.zoneReady.withLock { $0 = true }
            }
            return try await work(database)
        } catch {
            Self.log.error("CloudKit audio failed: \(error, privacy: .public)")
            DevLog.error("sync.audioFailed", error)
            throw SyncError.unreachable
        }
    }
}
