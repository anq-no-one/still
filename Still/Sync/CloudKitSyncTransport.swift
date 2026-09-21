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

    func push(_ changes: [SyncChange]) async throws {
        let records = changes.map { change -> CKRecord in
            let record = CKRecord(
                recordType: Self.recordType,
                recordID: CKRecord.ID(recordName: change.recordingID.uuidString)
            )
            record["updatedAt"] = change.updatedAt as NSDate
            record["deviceID"] = change.deviceID.uuidString as NSString
            record["payload"] = change.sealedRecording as NSData
            return record
        }

        do {
            _ = try await database().modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys)
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
