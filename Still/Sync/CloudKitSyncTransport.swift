import CloudKit
import Foundation
import OSLog

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
        let profile = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #else
        let profile = Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")
        #endif
        return FileManager.default.fileExists(atPath: profile.path)
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

            let wanted = changes.filter { $0.kind != .recording || $0.scopeID.map(scopes.contains) == true }
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
