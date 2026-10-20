import Foundation
import Security

/// The Library key and every project key, kept in iCloud Keychain so each
/// device signed in to the same Apple Account joins one Library without a
/// pairing code. iCloud Keychain is end-to-end encrypted, so CloudKit still
/// holds only ciphertext and Apple never sees a key.
struct SharedAccountKeys: Codable, Equatable, Sendable {
    let account: AccountInvitation
    var scopeKeys: [UUID: Data]

    func merging(_ other: SharedAccountKeys) -> SharedAccountKeys {
        guard other.account == account else { return self }
        return SharedAccountKeys(account: account, scopeKeys: other.scopeKeys.merging(scopeKeys) { mine, _ in mine })
    }
}

protocol SharedKeyStore: Sendable {
    func load() throws -> SharedAccountKeys?
    func save(_ keys: SharedAccountKeys) throws
}

struct ICloudKeychainSharedKeyStore: SharedKeyStore {
    private let service: String
    private let account = "shared-account-keys"

    init(service: String = "com.andrii.still.sync") {
        self.service = service
    }

    func load() throws -> SharedAccountKeys? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try JSONDecoder().decode(SharedAccountKeys.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw LibraryKeyError.keychainFailure(status)
        }
    }

    func save(_ keys: SharedAccountKeys) throws {
        let data = try JSONEncoder().encode(keys)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw LibraryKeyError.keychainFailure(update) }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw LibraryKeyError.keychainFailure(status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
