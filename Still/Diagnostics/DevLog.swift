import CryptoKit
import Foundation
import os
import Synchronization

/// Developer telemetry for Debug and TestFlight builds only. Unlike the
/// journal it may name what happened in free text, so it never runs in an App
/// Store build and every line is sealed on disk with the device journal key.
struct DevLogRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case event
        case error
        case span
        case interaction
        case hang
        case sample
        case counter
        case ai
    }

    var at: Date
    var uptime: Double
    var kind: Kind
    var name: String
    var ms: Double?
    var thread: String?
    var fields: [String: String]?
}

enum DevLogThread {
    static var current: String {
        guard !Thread.isMainThread else { return "main" }
        return "bg-\(qosName(qos_class_self()))"
    }

    static func qosName(_ qos: qos_class_t) -> String {
        switch qos {
        case QOS_CLASS_USER_INTERACTIVE: "userInteractive"
        case QOS_CLASS_USER_INITIATED: "userInitiated"
        case QOS_CLASS_DEFAULT: "default"
        case QOS_CLASS_UTILITY: "utility"
        case QOS_CLASS_BACKGROUND: "background"
        default: "unspecified"
        }
    }
}

enum DevLogClock {
    static let launchUptime: Double = {
        let now = ProcessInfo.processInfo.systemUptime
        guard let started = processStartedAt else { return now }
        return now - max(0, Date.now.timeIntervalSince(started))
    }()

    static var sinceLaunch: Double {
        ProcessInfo.processInfo.systemUptime - launchUptime
    }

    static var processStartedAt: Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

final class DevLogStream: Sendable {
    private struct Target {
        let directory: URL
        let name: String
        let cipher: LibraryCipher
    }

    private struct State {
        var target: Target?
        var isEnabled: Bool?
        var pending: [DevLogRecord] = []
        var flushScheduled = false
        var mirrors = true
    }

    static let heldLimit = 20_000

    let category: String
    private let maximumFileBytes: Int
    private let state = Mutex(State())
    private let queue: DispatchQueue
    private let logger: Logger

    init(category: String, maximumFileBytes: Int = 24 * 1024 * 1024) {
        self.category = category
        self.maximumFileBytes = maximumFileBytes
        queue = DispatchQueue(label: "com.andrii.still.devlog.\(category)", qos: .utility)
        logger = Logger(subsystem: "com.andrii.still", category: category)
    }

    var isEnabled: Bool {
        state.withLock { $0.isEnabled == true }
    }

    var isDisabled: Bool {
        state.withLock { $0.isEnabled == false }
    }

    func configure(directory: URL, name: String, key: SymmetricKey) {
        state.withLock { $0.target = Target(directory: directory, name: name, cipher: LibraryCipher(key: key)) }
    }

    /// Records arrive before the build channel is known, so they wait here
    /// until it is. Disabling drops them and the files an earlier TestFlight
    /// install may have left behind.
    func setEnabled(_ enabled: Bool) {
        let target = state.withLock { state -> Target? in
            state.isEnabled = enabled
            if !enabled { state.pending.removeAll() }
            return state.target
        }
        if enabled {
            scheduleFlush(immediately: true)
        } else if let target {
            queue.async { Self.files(of: target).forEach { try? FileManager.default.removeItem(at: $0) } }
        }
    }

    func append(_ record: DevLogRecord) {
        let shouldFlushNow = state.withLock { state -> Bool? in
            if state.isEnabled == false { return nil }
            state.pending.append(record)
            if state.isEnabled == nil, state.pending.count > Self.heldLimit {
                state.pending.removeFirst(state.pending.count - Self.heldLimit)
            }
            return state.pending.count >= 256
        }
        guard let shouldFlushNow else { return }
        scheduleFlush(immediately: shouldFlushNow)
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.drain()
                continuation.resume()
            }
        }
    }

    /// Writes every stored record, oldest first, as plain JSON lines.
    func export(to destination: URL, where include: (DevLogRecord) -> Bool = { _ in true }) throws -> Int {
        guard let target = state.withLock({ $0.target }) else { return 0 }
        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let encoder = Self.plainEncoder
        var count = 0
        for file in Self.files(of: target).reversed() {
            try Self.forEachLine(in: file) { line in
                guard let sealed = Data(base64Encoded: line),
                      let plain = try? target.cipher.open(sealed),
                      let record = try? Self.decoder.decode(DevLogRecord.self, from: plain),
                      include(record)
                else { return }
                try output.write(contentsOf: try encoder.encode(record) + Data([UInt8(ascii: "\n")]))
                count += 1
            }
        }
        return count
    }

    func records(where include: (DevLogRecord) -> Bool = { _ in true }) throws -> [DevLogRecord] {
        guard let target = state.withLock({ $0.target }) else { return [] }
        var records: [DevLogRecord] = []
        for file in Self.files(of: target).reversed() {
            try Self.forEachLine(in: file) { line in
                guard let sealed = Data(base64Encoded: line),
                      let plain = try? target.cipher.open(sealed),
                      let record = try? Self.decoder.decode(DevLogRecord.self, from: plain),
                      include(record)
                else { return }
                records.append(record)
            }
        }
        return records
    }

    var storedBytes: Int {
        guard let target = state.withLock({ $0.target }) else { return 0 }
        return Self.files(of: target).reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func scheduleFlush(immediately: Bool) {
        let schedule = state.withLock { state -> Bool in
            guard state.isEnabled == true else { return false }
            if immediately { return true }
            guard !state.flushScheduled else { return false }
            state.flushScheduled = true
            return true
        }
        guard schedule else { return }
        if immediately {
            queue.async { self.drain() }
        } else {
            queue.asyncAfter(deadline: .now() + 1) { self.drain() }
        }
    }

    private func drain() {
        let (records, target) = state.withLock { state -> ([DevLogRecord], Target?) in
            guard state.isEnabled == true else { return ([], nil) }
            state.flushScheduled = false
            let records = state.pending
            state.pending.removeAll(keepingCapacity: true)
            return (records, state.target)
        }
        guard !records.isEmpty else { return }
        for record in records {
            mirror(record)
        }
        guard let target else { return }

        var blob = Data()
        for record in records {
            guard let json = try? Self.sealedEncoder.encode(record),
                  let sealed = try? target.cipher.seal(json)
            else { continue }
            blob.append(sealed.base64EncodedData())
            blob.append(UInt8(ascii: "\n"))
        }
        write(blob, to: target)
    }

    private func mirror(_ record: DevLogRecord) {
        let duration = record.ms.map { String(format: " %.1fms", $0) } ?? ""
        let fields = record.fields.map { " " + $0.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.prefix(200))" }.joined(separator: " ") } ?? ""
        logger.debug("\(record.kind.rawValue, privacy: .public) \(record.name, privacy: .public)\(duration, privacy: .public) [\(record.thread ?? "-", privacy: .public)]\(fields, privacy: .public)")
    }

    private func write(_ blob: Data, to target: Target) {
        let url = Self.currentFile(of: target)
        do {
            try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil, attributes: Self.protection)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            try handle.write(contentsOf: blob)
            if Int(end) + blob.count > maximumFileBytes {
                try? handle.close()
                let previous = Self.previousFile(of: target)
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: url, to: previous)
            }
        } catch {
            logger.error("devlog write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func currentFile(of target: Target) -> URL {
        target.directory.appending(path: "\(target.name).jsonl")
    }

    private static func previousFile(of target: Target) -> URL {
        target.directory.appending(path: "\(target.name).1.jsonl")
    }

    /// Newest first.
    private static func files(of target: Target) -> [URL] {
        [currentFile(of: target), previousFile(of: target)]
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    private static func forEachLine(in url: URL, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                try body(Data(line))
            }
        }
        if !pending.isEmpty { try body(pending) }
    }

    private static var protection: [FileAttributeKey: Any]? {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }

    private static var sealedEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var plainEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum DevLog {
    static let main = DevLogStream(category: "devlog")
    static let ai = DevLogStream(category: "ai", maximumFileBytes: 48 * 1024 * 1024)

    static var isEnabled: Bool {
        main.isEnabled
    }

    static func event(_ name: String, _ fields: [String: String] = [:]) {
        main.append(record(.event, name, fields: fields))
    }

    static func error(_ name: String, _ error: (any Error)?, _ fields: [String: String] = [:]) {
        var fields = fields
        if let error {
            fields["error"] = String(describing: error)
            fields["errorCode"] = JournalErrorCode.of(error)
        }
        main.append(record(.error, name, fields: fields))
    }

    static func record(
        _ kind: DevLogRecord.Kind,
        _ name: String,
        ms: Double? = nil,
        thread: String? = DevLogThread.current,
        fields: [String: String] = [:]
    ) -> DevLogRecord {
        DevLogRecord(
            at: .now,
            uptime: DevLogClock.sinceLaunch,
            kind: kind,
            name: name,
            ms: ms,
            thread: thread,
            fields: fields.isEmpty ? nil : fields
        )
    }
}
