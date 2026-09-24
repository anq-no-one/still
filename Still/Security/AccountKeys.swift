import CryptoKit
import Foundation

struct AccountKeys: Codable, Equatable, Sendable {
    let accountID: UUID
    let createdAt: Date
    let noProjectScopeID: UUID
    private(set) var scopeKeys: [UUID: Data]

    init(accountID: UUID, createdAt: Date, noProjectScopeID: UUID, scopeKeys: [UUID: Data] = [:]) {
        self.accountID = accountID
        self.createdAt = createdAt
        self.noProjectScopeID = noProjectScopeID
        self.scopeKeys = scopeKeys
    }

    static func founding(projects: [UUID], at date: Date) -> AccountKeys {
        var keys = AccountKeys(accountID: UUID(), createdAt: date, noProjectScopeID: UUID())
        for scope in projects + [keys.noProjectScopeID] {
            keys.hold(SymmetricKey(size: .bits256), for: scope)
        }
        return keys
    }

    func joining(_ invitation: AccountInvitation) -> AccountKeys {
        AccountKeys(
            accountID: invitation.accountID,
            createdAt: invitation.createdAt,
            noProjectScopeID: invitation.noProjectScopeID,
            scopeKeys: scopeKeys.filter { $0.key != noProjectScopeID }
        )
    }

    var heldScopeIDs: Set<UUID> {
        Set(scopeKeys.keys)
    }

    func key(for scope: UUID) -> SymmetricKey? {
        scopeKeys[scope].map(SymmetricKey.init(data:))
    }

    mutating func hold(_ key: SymmetricKey, for scope: UUID) {
        scopeKeys[scope] = key.rawBytes
    }

    func renewingScopeKeys() -> AccountKeys {
        var renewed = self
        for scope in heldScopeIDs {
            renewed.hold(SymmetricKey(size: .bits256), for: scope)
        }
        return renewed
    }

    mutating func release(_ scope: UUID) {
        scopeKeys.removeValue(forKey: scope)
    }

    static func load(from url: URL, cipher: LibraryCipher) throws -> AccountKeys? {
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(AccountKeys.self, from: try cipher.open(sealed))
    }

    func save(to url: URL, cipher: LibraryCipher) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cipher.seal(try JSONEncoder().encode(self)).write(to: url, options: .atomic)
    }
}

struct AccountInvitation: Codable, Equatable, Sendable {
    let accountKey: Data
    let accountID: UUID
    let createdAt: Date
    let noProjectScopeID: UUID
}
