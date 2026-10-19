import CryptoKit
import Foundation
import Observation

/// Closed vocabulary for the journal. A code names what happened and never
/// carries text a person wrote, said, or chose, so nothing sensitive can leak in.
enum JournalCode: String, Codable, CaseIterable, Sendable {
    case appLaunched
    case libraryUnlockStarted
    case libraryUnlocked
    case libraryUnlockFailed
    case libraryLocked
    case setupStepShown
    case recordingStarted
    case recordingSaved
    case speakersNamed
    case recordingCancelled
    case recordingFailed
    case recordingDeleted
    case recordingArchived
    case recordingUnarchived
    case projectConfirmed
    case transcriptionFailed
    case modelDownloadFailed
    case importStarted
    case importSaved
    case importFailed
    case syncStarted
    case syncFinished
    case syncFailed
    case exportFinished
    case exportFailed
    case journalExported
}

struct JournalBreadcrumb: Codable, Equatable, Sendable {
    let at: Date
    let code: JournalCode
}

struct JournalEntry: Codable, Equatable, Sendable {
    let at: Date
    let appVersion: String
    let code: JournalCode
    let errorCode: String?
    let correlationID: UUID?
    let detail: String?
    let breadcrumbs: [JournalBreadcrumb]
}

/// Maps any error to its domain and numeric code. Both come from the code that
/// threw, not from user data, so they are safe to keep.
enum JournalErrorCode {
    static func of(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain)#\(error.code)"
    }
}

@MainActor
@Observable
final class DiagnosticJournal {
    static let breadcrumbLimit = 100
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    let fileURL: URL
    let lines: JournalLines
    private let appVersion: String
    private let now: () -> Date
    private var breadcrumbs: [JournalBreadcrumb] = []

    private(set) var writeProblem: String?

    init(
        fileURL: URL,
        key: SymmetricKey,
        appVersion: String = Diagnostics.systemEnvironment().appVersion,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        lines = JournalLines(cipher: LibraryCipher(key: key))
        self.appVersion = appVersion
        self.now = now
    }

    func note(_ code: JournalCode) {
        breadcrumbs.append(JournalBreadcrumb(at: now(), code: code))
        if breadcrumbs.count > Self.breadcrumbLimit {
            breadcrumbs.removeFirst(breadcrumbs.count - Self.breadcrumbLimit)
        }
    }

    static let detailLimit = 4096

    func record(_ code: JournalCode, correlationID: UUID? = nil, detail: String? = nil) {
        var fields: [String: String] = [:]
        if let correlationID { fields["recordingID"] = correlationID.uuidString }
        if let detail { fields["detail"] = detail }
        DevLog.event("journal.\(code.rawValue)", fields)
        note(code)
        append(
            JournalEntry(
                at: now(),
                appVersion: appVersion,
                code: code,
                errorCode: nil,
                correlationID: correlationID,
                detail: Self.clipped(detail),
                breadcrumbs: []
            )
        )
    }

    var storedBytes: Int {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.size] as? Int) ?? 0
    }

    @discardableResult
    func fail(_ code: JournalCode, error: (any Error)? = nil, correlationID: UUID = UUID()) -> UUID {
        DevLog.error("journal.\(code.rawValue)", error, ["recordingID": correlationID.uuidString])
        let entry = JournalEntry(
            at: now(),
            appVersion: appVersion,
            code: code,
            errorCode: error.map(JournalErrorCode.of),
            correlationID: correlationID,
            detail: nil,
            breadcrumbs: breadcrumbs
        )
        note(code)
        append(entry)
        return correlationID
    }

    func entries() throws -> [JournalEntry] {
        var entries: [JournalEntry] = []
        try lines.forEach(in: fileURL) { entries.append($0) }
        return entries
    }

    func export(to destination: URL) throws {
        try JournalExport.write(from: fileURL, lines: lines, to: destination)
        note(.journalExported)
    }

    func removeExpired() throws {
        let cutoff = now().addingTimeInterval(-Self.retention)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }

        let kept = fileURL.appendingPathExtension("trimmed")
        FileManager.default.createFile(atPath: kept.path(percentEncoded: false), contents: nil)
        let output = try FileHandle(forWritingTo: kept)
        do {
            try lines.forEach(in: fileURL) { entry in
                guard entry.at >= cutoff else { return }
                try output.write(contentsOf: try lines.encode(entry))
            }
            try output.close()
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: kept)
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: kept)
            throw error
        }
    }

    private static func clipped(_ detail: String?) -> String? {
        guard var detail else { return nil }
        while detail.utf8.count > detailLimit {
            detail.removeLast()
        }
        return detail
    }

    private func append(_ entry: JournalEntry) {
        do {
            let line = try lines.encode(entry)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil, attributes: Self.protection)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            writeProblem = nil
        } catch {
            writeProblem = String(
                localized: "Still could not save its diagnostic journal. Free up some storage, then try again. (\(JournalErrorCode.of(error)))"
            )
        }
    }

    private static var protection: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }
}

struct JournalLines: Sendable {
    let cipher: LibraryCipher

    func encode(_ entry: JournalEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let sealed = try cipher.seal(try encoder.encode(entry))
        return sealed.base64EncodedData() + Data([UInt8(ascii: "\n")])
    }

    func decode(_ line: Data) throws -> JournalEntry {
        guard let sealed = Data(base64Encoded: line) else { throw CocoaError(.coderReadCorrupt) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JournalEntry.self, from: try cipher.open(sealed))
    }

    /// Reads the file a chunk at a time so a long journal never sits in memory whole.
    func forEach(in url: URL, chunkSize: Int = 64 * 1024, _ body: (JournalEntry) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var pending = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let entry = try? decode(Data(line)) {
                    try body(entry)
                }
            }
        }
        if !pending.isEmpty, let entry = try? decode(pending) {
            try body(entry)
        }
    }
}

enum JournalExport {
    static func write(from source: URL, lines: JournalLines, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        try output.write(contentsOf: Data("Still diagnostic journal\n".utf8))
        try lines.forEach(in: source) { entry in
            try output.write(contentsOf: Data(text(for: entry).utf8))
        }
    }

    static func text(for entry: JournalEntry) -> String {
        let time = entry.at.formatted(.iso8601)
        var lines = ["\(time) \(entry.code.rawValue) version=\(entry.appVersion)"]
        if let errorCode = entry.errorCode {
            lines[0] += " error=\(errorCode)"
        }
        if let correlationID = entry.correlationID {
            lines[0] += " id=\(correlationID.uuidString)"
        }
        if let detail = entry.detail {
            lines[0] += " detail=\(detail)"
        }
        lines += entry.breadcrumbs.map { "  \($0.at.formatted(.iso8601)) \($0.code.rawValue)" }
        return lines.joined(separator: "\n") + "\n"
    }
}
