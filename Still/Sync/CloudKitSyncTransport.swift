import CloudKit
import Foundation

/// Carries sealed payloads through the user's own private CloudKit database.
/// The record fields hold ciphertext and ordering metadata only.
///
/// The iCloud container is resolved on first use rather than at launch, because
/// asking for one without the entitlement traps. A build without iCloud
/// provisioning therefore runs normally and only reports sync as unreachable.
struct CloudKitSyncTransport: SyncTransport {
    static let recordType = "StillSyncChange"

    private let container: @Sendable () -> CKContainer?

    init(container: @escaping @Sendable () -> CKContainer? = { CKContainer.default() }) {
        self.container = container
    }

    private func database() throws -> CKDatabase {
        guard let container = container() else { throw SyncError.unreachable }
        return container.privateCloudDatabase
    }

    /// CloudKit rejects a freshly built record that already exists on the
    /// server, because it carries no change tag. Existing records are fetched
    /// and edited in place so the second sync of a Recording behaves like the
    /// first.
    func push(_ changes: [SyncChange]) async throws {
        let database = try database()
        let ids = changes.map { CKRecord.ID(recordName: $0.recordingID.uuidString) }

        do {
            let existing = try await database.records(for: ids)
            let records = changes.map { change -> CKRecord in
                let id = CKRecord.ID(recordName: change.recordingID.uuidString)
                let record = (try? existing[id]?.get()) ?? CKRecord(recordType: Self.recordType, recordID: id)
                record["updatedAt"] = change.updatedAt as NSDate
                record["deviceID"] = change.deviceID.uuidString as NSString
                record["payload"] = change.sealedRecording as NSData
                return record
            }

            _ = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
        } catch {
            throw SyncError.unreachable
        }
    }

    func pull(since: Date?) async throws -> [SyncChange] {
        let predicate = since.map { NSPredicate(format: "updatedAt > %@", $0 as NSDate) } ?? NSPredicate(value: true)
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: true)]

        do {
            let (results, _) = try await database().records(matching: query)
            return results.compactMap { id, result in
                guard let record = try? result.get(),
                      let recordingID = UUID(uuidString: id.recordName),
                      let updatedAt = record["updatedAt"] as? Date,
                      let deviceID = (record["deviceID"] as? String).flatMap(UUID.init(uuidString:)),
                      let payload = record["payload"] as? Data
                else { return nil }

                return SyncChange(
                    recordingID: recordingID,
                    updatedAt: updatedAt,
                    deviceID: deviceID,
                    sealedRecording: payload
                )
            }
        } catch {
            throw SyncError.unreachable
        }
    }
}
