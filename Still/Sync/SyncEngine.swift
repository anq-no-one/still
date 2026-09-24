import CryptoKit
import Foundation
import Observation

protocol SyncSettingsStore: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool)
    func lastSyncedAt() -> Date?
    func setLastSyncedAt(_ date: Date)
}

@MainActor
@Observable
final class SyncEngine {
    struct JoinRequest: Identifiable, Equatable {
        let device: DeviceRecord
        let code: String

        var id: UUID {
            device.id
        }
    }

    struct JoinTarget: Identifiable, Equatable {
        let id: UUID
        let kind: DeviceKind
        let code: String
    }

    struct Invitation: Equatable {
        let account: AccountInvitation
        let from: DeviceKind?
        let code: String
    }

    private let library: Library
    private let transport: SyncTransport
    private let settings: SyncSettingsStore
    private let identity: DeviceIdentity
    private let now: () -> Date

    private(set) var isEnabled: Bool
    private(set) var lastFailure: String?
    private(set) var lastSyncedAt: Date?
    private(set) var joinRequests: [JoinRequest] = []
    private(set) var joinTargets: [JoinTarget] = []
    private(set) var invitation: Invitation?

    init(
        library: Library,
        transport: SyncTransport,
        settings: SyncSettingsStore,
        identity: DeviceIdentity = DeviceIdentity(),
        now: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.transport = transport
        self.settings = settings
        self.identity = identity
        self.now = now
        isEnabled = settings.isEnabled()
        lastSyncedAt = settings.lastSyncedAt()
    }

    var deviceID: UUID {
        identity.id
    }

    static let whatLeavesTheDevice = String(localized: """
        Sync sends your recordings to your own iCloud account, encrypted on this device \
        first. Apple stores only ciphertext: no transcript, note, audio, or key ever leaves in \
        readable form. Each project has its own key, so a device only receives the projects it \
        keeps. Text and notes arrive on your other devices before the audio finishes.
        """)

    func enable() {
        isEnabled = true
        settings.setEnabled(true)
    }

    func disable() {
        isEnabled = false
        settings.setEnabled(false)
    }

    func syncIfEnabled() async {
        guard isEnabled else { return }
        await sync()
    }

    func sync() async {
        guard isEnabled else {
            lastFailure = SyncError.disabled.localizedDescription
            return
        }

        let correlationID = UUID()
        library.journal?.record(.syncStarted, correlationID: correlationID)
        do {
            var server = ServerState(try await transport.pull(payloadsFor: library.heldScopeIDs), library: library)
            if try receiveGrants(from: server) {
                server = ServerState(try await transport.pull(payloadsFor: library.heldScopeIDs), library: library)
            }
            try apply(server)
            let outgoing = try outgoingChanges(against: server)
            if !outgoing.isEmpty {
                try await transport.push(outgoing)
            }
            try releaseLeavingScopes(server: server, pushed: outgoing)
            refreshJoining(server)

            let stamp = now()
            settings.setLastSyncedAt(stamp)
            lastSyncedAt = stamp
            lastFailure = nil
            library.journal?.record(.syncFinished, correlationID: correlationID)
        } catch {
            lastFailure = error.localizedDescription
            library.journal?.fail(.syncFailed, error: error, correlationID: correlationID)
        }
    }

    func approve(_ request: JoinRequest) async {
        do {
            let invitation = try JSONEncoder().encode(try library.accountInvitation())
            try await transport.push([
                SyncChange(
                    id: KeyGrant.id(recipient: request.device.id, subject: nil),
                    kind: .grant,
                    updatedAt: now(),
                    deviceID: identity.id,
                    recipientID: request.device.id,
                    payload: try KeyGrant.seal(invitation, subject: nil, to: request.device, from: identity)
                ),
            ])
            joinRequests.removeAll { $0.id == request.id }
            lastFailure = nil
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    func acceptInvitation() async {
        guard let invitation else { return }

        do {
            try await library.join(invitation.account)
            self.invitation = nil
            lastFailure = nil
        } catch {
            lastFailure = error.localizedDescription
            return
        }
        await syncIfEnabled()
    }

    private func receiveGrants(from server: ServerState) throws -> Bool {
        var gained = false
        invitation = nil

        for grant in server.grants(to: identity.id) {
            guard let payload = grant.payload,
                  let opened = try? KeyGrant.open(payload, subject: grant.scopeID, as: identity)
            else { continue }

            if let scope = grant.scopeID {
                guard server.trustedKeys.contains(opened.sender),
                      library.requestedScopeIDs.contains(scope),
                      !library.heldScopeIDs.contains(scope)
                else { continue }

                try library.hold(SymmetricKey(data: opened.secret), forScope: scope)
                gained = true
            } else if let account = try? JSONDecoder().decode(AccountInvitation.self, from: opened.secret),
                      account.accountID != library.accountID {
                invitation = Invitation(
                    account: account,
                    from: server.devices.values.first { $0.publicKey == opened.sender }?.kind,
                    code: VerificationCode.between(opened.sender, identity.publicKey)
                )
            }
        }

        return gained
    }

    private func apply(_ server: ServerState) throws {
        let held = library.heldScopeIDs

        for change in server.changes where change.deviceID != identity.id {
            switch change.kind {
            case .project:
                guard let payload = change.payload,
                      let remote = try? library.openProjectSyncPayload(payload)
                else { continue }
                try library.applyRemote(remote)
            case .recording:
                if let scope = change.scopeID, held.contains(scope) {
                    guard let remote = try? library.openRecording(from: change) else { continue }
                    try library.applyRemote(remote)
                } else if change.scopeID != nil,
                          let local = library.storedRecordings.first(where: { $0.id == change.id }),
                          local.isProjectConfirmed,
                          local.updatedAt < change.updatedAt {
                    try library.purgeLocalCopy(ofRecording: change.id)
                }
            case .device, .trust, .grant:
                continue
            }
        }
    }

    private func outgoingChanges(against server: ServerState) throws -> [SyncChange] {
        guard let accountID = library.accountID, let accountCreatedAt = library.accountCreatedAt else {
            throw LibraryError.locked
        }

        let stamp = now()
        var outgoing: [SyncChange] = []

        let record = DeviceRecord(
            id: identity.id,
            kind: identity.kind,
            publicKey: identity.publicKey,
            accountID: accountID,
            accountCreatedAt: accountCreatedAt,
            requestedScopes: library.requestedScopeIDs,
            heldScopes: library.heldScopeIDs
        )
        if server.devices[identity.id] != record {
            outgoing.append(
                SyncChange(
                    id: identity.id,
                    kind: .device,
                    updatedAt: stamp,
                    deviceID: identity.id,
                    payload: try JSONEncoder().encode(record)
                )
            )
        }

        if server.trust[identity.id] != identity.publicKey {
            outgoing.append(
                SyncChange(
                    id: identity.id,
                    kind: .trust,
                    updatedAt: stamp,
                    deviceID: identity.id,
                    payload: try library.sealForAccount(identity.publicKey)
                )
            )
        }

        for grant in server.grants(to: identity.id) where isSettled(grant) {
            outgoing.append(
                SyncChange(
                    id: grant.id,
                    kind: .grant,
                    updatedAt: stamp,
                    deviceID: identity.id,
                    scopeID: grant.scopeID,
                    recipientID: identity.id,
                    payload: Data()
                )
            )
        }

        for device in server.members(of: accountID) where device.id != identity.id {
            let wanted = device.requestedScopes.subtracting(device.heldScopes).intersection(library.heldScopeIDs)
            for scope in wanted {
                let id = KeyGrant.id(recipient: device.id, subject: scope)
                guard server.grant(id)?.payload?.isEmpty != false, let key = library.scopeKey(for: scope) else {
                    continue
                }

                outgoing.append(
                    SyncChange(
                        id: id,
                        kind: .grant,
                        updatedAt: stamp,
                        deviceID: identity.id,
                        scopeID: scope,
                        recipientID: device.id,
                        payload: try KeyGrant.seal(key.rawBytes, subject: scope, to: device, from: identity)
                    )
                )
            }
        }

        for project in library.storedProjects where server.project(project.id) != project {
            outgoing.append(
                SyncChange(
                    id: project.id,
                    kind: .project,
                    updatedAt: project.updatedAt,
                    deviceID: identity.id,
                    payload: try library.sealForSync(project)
                )
            )
        }

        for recording in library.storedRecordings where recording.isProjectConfirmed {
            guard server.recording(recording.id) != recording,
                  let change = try library.syncChange(for: recording, deviceID: identity.id)
            else { continue }
            outgoing.append(change)
        }

        return outgoing
    }

    private func isSettled(_ grant: SyncChange) -> Bool {
        guard let scope = grant.scopeID else { return invitation == nil }
        return library.heldScopeIDs.contains(scope) || !library.requestedScopeIDs.contains(scope)
    }

    private func releaseLeavingScopes(server: ServerState, pushed: [SyncChange]) throws {
        guard let accountID = library.accountID else { return }

        var copies = server.recordingHeaders
        for change in pushed where change.kind == .recording {
            copies[change.id] = change
        }
        let keepers = server.members(of: accountID).filter { $0.id != identity.id }

        for scope in library.heldScopeIDs.subtracting(library.requestedScopeIDs) {
            let keptElsewhere = keepers.contains { $0.heldScopes.contains(scope) && $0.requestedScopes.contains(scope) }
            let everyCopyIsUp = library.confirmedRecordings(inScope: scope).allSatisfy { recording in
                copies[recording.id].map { $0.scopeID == scope && $0.updatedAt >= recording.updatedAt } ?? false
            }
            guard keptElsewhere, everyCopyIsUp else { continue }

            try library.releaseScope(scope)
        }
    }

    private func refreshJoining(_ server: ServerState) {
        guard let accountID = library.accountID, let createdAt = library.accountCreatedAt else { return }

        let others = server.devices.values.filter { $0.id != identity.id && $0.accountID != accountID }
        joinRequests = others
            .filter { $0.isNewer(thanAccount: accountID, createdAt: createdAt) }
            .filter { server.grant(KeyGrant.id(recipient: $0.id, subject: nil))?.payload?.isEmpty != false }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { JoinRequest(device: $0, code: VerificationCode.between($0.publicKey, identity.publicKey)) }
        joinTargets = others
            .filter { !$0.isNewer(thanAccount: accountID, createdAt: createdAt) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { JoinTarget(id: $0.id, kind: $0.kind, code: VerificationCode.between($0.publicKey, identity.publicKey)) }
    }
}

@MainActor
private struct ServerState {
    let changes: [SyncChange]
    let devices: [UUID: DeviceRecord]
    let trust: [UUID: Data]
    private let byKey: [String: SyncChange]
    private let library: Library

    init(_ changes: [SyncChange], library: Library) {
        self.changes = changes
        self.library = library
        byKey = Dictionary(changes.map { (Self.key($0.kind, $0.id), $0) }, uniquingKeysWith: { _, last in last })
        devices = Dictionary(
            changes.compactMap { change -> (UUID, DeviceRecord)? in
                guard change.kind == .device,
                      let payload = change.payload,
                      let record = try? JSONDecoder().decode(DeviceRecord.self, from: payload),
                      record.id == change.id
                else { return nil }
                return (record.id, record)
            },
            uniquingKeysWith: { _, last in last }
        )
        trust = Dictionary(
            changes.compactMap { change -> (UUID, Data)? in
                guard change.kind == .trust,
                      let payload = change.payload,
                      let publicKey = try? library.openFromAccount(payload)
                else { return nil }
                return (change.id, publicKey)
            },
            uniquingKeysWith: { _, last in last }
        )
    }

    private static func key(_ kind: SyncChange.Kind, _ id: UUID) -> String {
        kind.rawValue + "-" + id.uuidString
    }

    var trustedKeys: Set<Data> {
        Set(trust.values)
    }

    var recordingHeaders: [UUID: SyncChange] {
        Dictionary(changes.filter { $0.kind == .recording }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    func members(of accountID: UUID) -> [DeviceRecord] {
        devices.values.filter { $0.accountID == accountID && trustedKeys.contains($0.publicKey) }
    }

    func grants(to recipient: UUID) -> [SyncChange] {
        changes.filter { $0.kind == .grant && $0.recipientID == recipient && $0.payload?.isEmpty == false }
    }

    func grant(_ id: UUID) -> SyncChange? {
        byKey[Self.key(.grant, id)]
    }

    func project(_ id: UUID) -> Project? {
        byKey[Self.key(.project, id)]?.payload.flatMap { try? library.openProjectSyncPayload($0) }
    }

    func recording(_ id: UUID) -> Recording? {
        byKey[Self.key(.recording, id)].flatMap { try? library.openRecording(from: $0) }
    }
}

struct UserDefaultsSyncSettings: SyncSettingsStore, @unchecked Sendable {
    private let enabledKey = "still.sync.enabled"
    private let syncedKey = "still.sync.lastSyncedAt"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled() -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: enabledKey)
    }

    func lastSyncedAt() -> Date? {
        defaults.object(forKey: syncedKey) as? Date
    }

    func setLastSyncedAt(_ date: Date) {
        defaults.set(date, forKey: syncedKey)
    }
}
