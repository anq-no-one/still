import CloudKit
import Foundation

/// Bug reports in the user's own private iCloud database, in a zone apart
/// from the Library. Records reuse the deployed `StillSyncChange` type, so a
/// TestFlight build needs no schema change in production.
struct CloudKitBugReportTransport: BugReportTransport {
    static let zoneID = CKRecordZone.ID(zoneName: "BugReports")
    private static let manifestKind = "bugReport"
    private static let partKind = "bugReportPart"
    private static let partsPerRequest = 8

    private let deviceID: UUID
    private let container: @Sendable () -> CKContainer?

    init(
        deviceID: UUID,
        container: @escaping @Sendable () -> CKContainer? = { CloudKitSyncTransport.isProvisioned ? CKContainer.default() : nil }
    ) {
        self.deviceID = deviceID
        self.container = container
    }

    func send(_ id: UUID, manifest: Data, parts: [Data], progress: @escaping @Sendable (Int) -> Void) async throws {
        try await reachingCloudKit { database in
            var sent = 0
            for start in stride(from: 0, to: parts.count, by: Self.partsPerRequest) {
                let batch = (start..<min(start + Self.partsPerRequest, parts.count)).map { index in
                    record(Self.partName(id, index), kind: Self.partKind, payload: parts[index])
                }
                try Self.check(try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .allKeys).saveResults)
                sent += batch.count
                progress(sent)
            }
            let index = record(Self.manifestName(id), kind: Self.manifestKind, payload: manifest)
            try Self.check(try await database.modifyRecords(saving: [index], deleting: [], savePolicy: .allKeys).saveResults)
        }
    }

    func waiting() async throws -> [UUID: Data] {
        try await reachingCloudKit { database in
            var names: [CKRecord.ID] = []
            var token: CKServerChangeToken?
            var moreComing = true
            while moreComing {
                let batch = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token, desiredKeys: ["kind"])
                names += batch.modificationResultsByID.compactMap { id, result in
                    ((try? result.get())?.record["kind"] as? String) == Self.manifestKind ? id : nil
                }
                token = batch.changeToken
                moreComing = batch.moreComing
            }
            guard !names.isEmpty else { return [:] }
            var manifests: [UUID: Data] = [:]
            for (id, result) in try await database.records(for: names, desiredKeys: ["payload"]) {
                guard let reportID = UUID(uuidString: String(id.recordName.dropFirst("bugreport-".count))),
                      let payload = (try? result.get())?["payload"] as? Data
                else { continue }
                manifests[reportID] = payload
            }
            return manifests
        }
    }

    func parts(of id: UUID, count: Int) async throws -> [Data] {
        try await reachingCloudKit { database in
            var parts: [Data] = []
            for start in stride(from: 0, to: count, by: Self.partsPerRequest) {
                let ids = (start..<min(start + Self.partsPerRequest, count)).map { Self.recordID(Self.partName(id, $0)) }
                let results = try await database.records(for: ids, desiredKeys: ["payload"])
                for recordID in ids {
                    guard let payload = (try? results[recordID]?.get())?["payload"] as? Data else {
                        throw BugReportError.missingParts
                    }
                    parts.append(payload)
                }
            }
            return parts
        }
    }

    func remove(_ id: UUID, parts: Int) async throws {
        try await reachingCloudKit { database in
            let ids = [Self.recordID(Self.manifestName(id))] + (0..<parts).map { Self.recordID(Self.partName(id, $0)) }
            for start in stride(from: 0, to: ids.count, by: 200) {
                _ = try await database.modifyRecords(saving: [], deleting: Array(ids[start..<min(start + 200, ids.count)]))
            }
        }
    }

    private func record(_ name: String, kind: String, payload: Data) -> CKRecord {
        let record = CKRecord(recordType: CloudKitSyncTransport.recordType, recordID: Self.recordID(name))
        record["kind"] = kind as NSString
        record["updatedAt"] = Date() as NSDate
        record["deviceID"] = deviceID.uuidString as NSString
        record["payload"] = payload as NSData
        return record
    }

    private static func check(_ results: [CKRecord.ID: Result<CKRecord, any Error>]) throws {
        for result in results.values {
            if case .failure(let error) = result { throw error }
        }
    }

    private static func manifestName(_ id: UUID) -> String {
        "bugreport-\(id.uuidString)"
    }

    private static func partName(_ id: UUID, _ index: Int) -> String {
        "bugreportpart-\(id.uuidString)-\(index)"
    }

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func reachingCloudKit<Result>(_ work: (CKDatabase) async throws -> Result) async throws -> Result {
        guard let container = container() else {
            DevLog.event("bugReport.noContainer", ["provisioned": String(CloudKitSyncTransport.isProvisioned)])
            throw SyncError.unreachable
        }
        await CloudKitSyncTransport.reportAccount(of: container)
        let database = container.privateCloudDatabase
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
            return try await work(database)
        } catch let error as BugReportError {
            throw error
        } catch {
            DevLog.error("bugReport.cloudKitFailed", error, CloudKitDiagnostics.fields(for: error))
            throw error
        }
    }
}
