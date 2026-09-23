import CloudKit
import Foundation
import OSLog

/// Carries sealed payloads through the user's own private CloudKit database.
/// The record fields hold ciphertext and ordering metadata only.
///
/// Asking for a container without the iCloud entitlement traps, so a build
/// without a provisioning profile never asks and reports sync as unreachable.
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

    /// CloudKit rejects a freshly built record that already exists on the
    /// server, because it carries no change tag. Existing records are fetched
    /// and edited in place so the second sync of a Recording behaves like the
    /// first.
    func push(_ changes: [SyncChange]) async throws {
        try await reachingCloudKit { database in
            let ids = changes.map { CKRecord.ID(recordName: $0.recordingID.uuidString, zoneID: Self.zoneID) }
            let existing = try await database.records(for: ids)
            let records = changes.map { change -> CKRecord in
                let id = CKRecord.ID(recordName: change.recordingID.uuidString, zoneID: Self.zoneID)
                let record = (try? existing[id]?.get()) ?? CKRecord(recordType: Self.recordType, recordID: id)
                record["updatedAt"] = change.updatedAt as NSDate
                record["deviceID"] = change.deviceID.uuidString as NSString
                record["payload"] = change.sealedRecording as NSData
                return record
            }

            _ = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
        }
    }

    /// Zone changes need no server indexes, unlike a query, so a fresh iCloud
    /// container works without any schema set up by hand.
    func pull(since: Date?) async throws -> [SyncChange] {
        try await reachingCloudKit { database in
            var changes: [SyncChange] = []
            var token: CKServerChangeToken?
            var moreComing = true

            while moreComing {
                let batch = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
                changes += batch.modificationResultsByID.values.compactMap { result in
                    (try? result.get()).flatMap { Self.change(from: $0.record) }
                }
                token = batch.changeToken
                moreComing = batch.moreComing
            }

            return changes
                .filter { change in since.map { change.updatedAt > $0 } ?? true }
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

    private static func change(from record: CKRecord) -> SyncChange? {
        guard let recordingID = UUID(uuidString: record.recordID.recordName),
              let updatedAt = record["updatedAt"] as? Date,
              let deviceID = (record["deviceID"] as? String).flatMap(UUID.init(uuidString:)),
              let payload = record["payload"] as? Data
        else { return nil }

        return SyncChange(recordingID: recordingID, updatedAt: updatedAt, deviceID: deviceID, sealedRecording: payload)
    }
}
