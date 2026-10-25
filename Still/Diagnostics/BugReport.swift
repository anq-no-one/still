import CryptoKit
import Foundation
import Observation

struct BugReportAttachment: Equatable, Sendable {
    let name: String
    let data: Data
}

struct BugReportManifest: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var accountID: UUID
    var device: String
    var fileName: String
    var bytes: Int
    var parts: Int
    var sha256: String
}

enum BugReportError: LocalizedError, Equatable {
    case otherLibrary
    case damaged
    case missingParts

    var errorDescription: String? {
        switch self {
        case .otherLibrary: "This report comes from a device in another Still Library."
        case .damaged: "This report arrived damaged."
        case .missingParts: "Part of this report has not arrived yet."
        }
    }
}

/// A report travels as sealed parts small enough for one CloudKit record
/// each, under a key only devices in the same Library can derive.
enum BugReportPacking {
    static let partBytes = 900_000

    static func key(accountKey: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: accountKey),
            info: Data("still.bug-report.v1".utf8),
            outputByteCount: 32
        )
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func pack(_ zip: Data, manifest: BugReportManifest, key: SymmetricKey) throws -> (manifest: Data, parts: [Data]) {
        let cipher = LibraryCipher(key: key)
        let parts = try stride(from: 0, to: zip.count, by: partBytes).map { start in
            try cipher.seal(zip.subdata(in: start..<min(start + partBytes, zip.count)))
        }
        var manifest = manifest
        manifest.bytes = zip.count
        manifest.parts = parts.count
        manifest.sha256 = digest(zip)
        return (try cipher.seal(JSONEncoder().encode(manifest)), parts)
    }

    static func manifest(_ sealed: Data, key: SymmetricKey) throws -> BugReportManifest {
        guard let plain = try? LibraryCipher(key: key).open(sealed) else { throw BugReportError.otherLibrary }
        return try JSONDecoder().decode(BugReportManifest.self, from: plain)
    }

    static func unpack(_ parts: [Data], manifest: BugReportManifest, key: SymmetricKey) throws -> Data {
        guard parts.count == manifest.parts else { throw BugReportError.missingParts }
        let cipher = LibraryCipher(key: key)
        var zip = Data(capacity: manifest.bytes)
        for part in parts {
            guard let plain = try? cipher.open(part) else { throw BugReportError.damaged }
            zip.append(plain)
        }
        guard digest(zip) == manifest.sha256 else { throw BugReportError.damaged }
        return zip
    }
}

protocol BugReportTransport: Sendable {
    func send(_ id: UUID, manifest: Data, parts: [Data], progress: @escaping @Sendable (Int) -> Void) async throws
    func waiting() async throws -> [UUID: Data]
    func parts(of id: UUID, count: Int) async throws -> [Data]
    func remove(_ id: UUID, parts: Int) async throws
}

protocol BugReportSettingsStore: Sendable {
    func receives(byDefault: Bool) -> Bool
    func setReceives(_ receives: Bool)
}

struct UserDefaultsBugReportSettings: BugReportSettingsStore, @unchecked Sendable {
    private let key = "still.bugReports.receive"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func receives(byDefault: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? byDefault : defaults.bool(forKey: key)
    }

    func setReceives(_ receives: Bool) {
        defaults.set(receives, forKey: key)
    }
}

/// Sends a tester's report to the developer's Mac through their own iCloud,
/// and on that Mac collects every report into a folder an agent can read.
@MainActor
@Observable
final class BugReportCourier {
    enum SendState: Equatable {
        case idle
        case sending(sent: Int, of: Int)
        case sent
        case savedHere(URL)
        case failed(String)
    }

    private let transport: BugReportTransport
    private let settings: BugReportSettingsStore
    private let accountKey: @MainActor () throws -> (id: UUID, key: Data)
    private let device: String
    private let inbox: DebugBundleStore
    private let canReceive: Bool

    private(set) var sendState: SendState = .idle
    private(set) var received: [SavedBundle] = []
    private(set) var lastChecked: Date?
    private(set) var receiveProblem: String?
    private var checking = false

    init(
        transport: BugReportTransport,
        settings: BugReportSettingsStore,
        accountKey: @escaping @MainActor () throws -> (id: UUID, key: Data),
        device: String,
        inbox: DebugBundleStore = DebugBundleStore(directory: DebugBundleStore.bugReportsDirectory, keeps: 200),
        canReceive: Bool,
        receivesByDefault: Bool = false
    ) {
        self.transport = transport
        self.settings = settings
        self.accountKey = accountKey
        self.device = device
        self.inbox = inbox
        self.canReceive = canReceive
        receives = canReceive && settings.receives(byDefault: receivesByDefault)
        received = canReceive ? inbox.bundles() : []
    }

    var receives: Bool {
        didSet {
            guard canReceive else {
                receives = false
                return
            }
            settings.setReceives(receives)
        }
    }

    var offersReceiving: Bool {
        canReceive
    }

    var inboxDirectory: URL {
        inbox.directory
    }

    /// A Mac that collects reports keeps its own straight away; every other
    /// device sends through iCloud.
    func submit(_ zip: URL) async {
        do {
            if receives {
                let saved = try inbox.save(try Data(contentsOf: zip), named: zip.lastPathComponent)
                received = inbox.bundles()
                sendState = .savedHere(saved)
                DevLog.event("bugReport.savedHere", ["file": saved.lastPathComponent])
                return
            }
            let account = try accountKey()
            let key = BugReportPacking.key(accountKey: account.key)
            let data = try Data(contentsOf: zip)
            let manifest = BugReportManifest(
                id: UUID(),
                createdAt: .now,
                accountID: account.id,
                device: device,
                fileName: zip.lastPathComponent,
                bytes: data.count,
                parts: 0,
                sha256: ""
            )
            let packed = try BugReportPacking.pack(data, manifest: manifest, key: key)
            sendState = .sending(sent: 0, of: packed.parts.count)
            let total = packed.parts.count
            try await Perf.trace("bugReport.send", ["bytes": String(data.count), "parts": String(total)]) {
                try await transport.send(manifest.id, manifest: packed.manifest, parts: packed.parts) { sent in
                    Task { @MainActor [weak self] in self?.sendState = .sending(sent: sent, of: total) }
                }
            }
            sendState = .sent
            DevLog.event("bugReport.sent", ["report": manifest.id.uuidString, "bytes": String(data.count), "parts": String(total)])
        } catch {
            DevLog.error("bugReport.sendFailed", error)
            sendState = .failed(error.localizedDescription)
        }
    }

    func resetSendState() {
        sendState = .idle
    }

    /// Takes every waiting report into the inbox and then removes it from
    /// iCloud, so reports never pile up in the user's storage.
    func collect() async {
        guard receives, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let account = try accountKey()
            let key = BugReportPacking.key(accountKey: account.key)
            let waiting = try await transport.waiting()
            var collected = 0
            for (id, sealed) in waiting {
                do {
                    let manifest = try BugReportPacking.manifest(sealed, key: key)
                    let zip = try BugReportPacking.unpack(try await transport.parts(of: id, count: manifest.parts), manifest: manifest, key: key)
                    try inbox.save(zip, named: Self.inboxName(for: manifest))
                    try await transport.remove(id, parts: manifest.parts)
                    collected += 1
                    DevLog.event("bugReport.received", ["report": id.uuidString, "from": manifest.device, "bytes": String(zip.count)])
                } catch BugReportError.missingParts {
                    continue
                } catch {
                    DevLog.error("bugReport.receiveFailed", error, ["report": id.uuidString])
                    receiveProblem = error.localizedDescription
                }
            }
            if collected > 0 { received = inbox.bundles() }
            lastChecked = .now
            if collected > 0 || waiting.isEmpty { receiveProblem = nil }
        } catch {
            DevLog.error("bugReport.checkFailed", error)
            receiveProblem = error.localizedDescription
        }
    }

    func keepCollecting(every interval: Duration) {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.collect()
                try? await Task.sleep(for: interval)
            }
        }
    }

    static func inboxName(for manifest: BugReportManifest) -> String {
        let stamp = manifest.createdAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let device = manifest.device.filter { $0.isLetter || $0.isNumber }
        return "\(stamp)-\(device)-\(manifest.id.uuidString.prefix(8)).zip"
    }
}
