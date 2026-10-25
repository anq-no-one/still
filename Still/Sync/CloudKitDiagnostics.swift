import CloudKit
import Foundation
import Synchronization

/// CloudKit failures reach the app as one `SyncError.unreachable`, and
/// per-record failures inside a successful batch reach it as nothing at all.
/// This keeps the real code, retry hint and per-record outcomes in the log.
enum CloudKitDiagnostics {
    private static let reportedAccount = Mutex(false)

    static func fields(for error: any Error) -> [String: String] {
        let nsError = error as NSError
        var fields = ["domain": nsError.domain, "code": String(nsError.code)]
        guard let ckError = error as? CKError else { return fields }
        fields["ckError"] = name(of: ckError.code)
        if let retry = ckError.retryAfterSeconds { fields["retryAfterS"] = String(format: "%.0f", retry) }
        if let partial = ckError.partialErrorsByItemID, !partial.isEmpty {
            fields["partialErrors"] = summary(partial.values.map { $0 })
        }
        return fields
    }

    static func failures<Value>(_ results: [CKRecord.ID: Result<Value, any Error>]) -> String? {
        let errors = results.values.compactMap { result -> (any Error)? in
            if case .failure(let error) = result { return error }
            return nil
        }
        return errors.isEmpty ? nil : summary(errors)
    }

    static func summary(_ errors: [any Error]) -> String {
        let names = errors.map { error -> String in
            (error as? CKError).map { name(of: $0.code) } ?? "\((error as NSError).domain)#\((error as NSError).code)"
        }
        return Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    /// True only the first time it is asked, so the account status is read
    /// once per launch.
    static func shouldReportAccount() -> Bool {
        reportedAccount.withLock { reported in
            defer { reported = true }
            return !reported
        }
    }

    static func name(of status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .noAccount: "noAccount"
        case .restricted: "restricted"
        case .couldNotDetermine: "couldNotDetermine"
        case .temporarilyUnavailable: "temporarilyUnavailable"
        @unknown default: "unknown\(status.rawValue)"
        }
    }

    static func name(of code: CKError.Code) -> String {
        switch code {
        case .internalError: "internalError"
        case .partialFailure: "partialFailure"
        case .networkUnavailable: "networkUnavailable"
        case .networkFailure: "networkFailure"
        case .badContainer: "badContainer"
        case .serviceUnavailable: "serviceUnavailable"
        case .requestRateLimited: "requestRateLimited"
        case .missingEntitlement: "missingEntitlement"
        case .notAuthenticated: "notAuthenticated"
        case .permissionFailure: "permissionFailure"
        case .unknownItem: "unknownItem"
        case .invalidArguments: "invalidArguments"
        case .serverRecordChanged: "serverRecordChanged"
        case .serverRejectedRequest: "serverRejectedRequest"
        case .assetFileNotFound: "assetFileNotFound"
        case .assetFileModified: "assetFileModified"
        case .incompatibleVersion: "incompatibleVersion"
        case .constraintViolation: "constraintViolation"
        case .operationCancelled: "operationCancelled"
        case .changeTokenExpired: "changeTokenExpired"
        case .batchRequestFailed: "batchRequestFailed"
        case .zoneBusy: "zoneBusy"
        case .badDatabase: "badDatabase"
        case .quotaExceeded: "quotaExceeded"
        case .zoneNotFound: "zoneNotFound"
        case .limitExceeded: "limitExceeded"
        case .userDeletedZone: "userDeletedZone"
        case .tooManyParticipants: "tooManyParticipants"
        case .alreadyShared: "alreadyShared"
        case .referenceViolation: "referenceViolation"
        case .managedAccountRestricted: "managedAccountRestricted"
        case .participantMayNeedVerification: "participantMayNeedVerification"
        case .serverResponseLost: "serverResponseLost"
        case .assetNotAvailable: "assetNotAvailable"
        case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
        @unknown default: "ckError\(code.rawValue)"
        }
    }
}
