import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct KeychainDeviceKeySource: DeviceKeySource {
    private let service: String
    private let deviceKeyAccount = "library-device-key-unlocked"
    private let presenceDeviceKeyAccount = "library-device-key"
    private let masterKeyAccount = "library-master-key"
    private let recoveryAccount = "library-recovery"
    private let pendingMasterKeyAccount = "library-master-key-pending"

    static let defaultService = "com.andrii.still.library"

    init(service: String = Self.defaultService) {
        self.service = service
    }

    func deviceKey(reason: String) async throws -> SymmetricKey {
        if let existing = try read(account: deviceKeyAccount, context: nil) {
            return SymmetricKey(data: existing)
        }

        let context = LAContext()
        context.localizedReason = reason
        if let presenceKey = try readPresenceDeviceKey(context: context) {
            try keepWithoutPresence(presenceKey)
            return SymmetricKey(data: presenceKey)
        }

        let key = SymmetricKey(size: .bits256)
        try write(key.rawBytes, account: deviceKeyAccount)
        return key
    }

    private func keepWithoutPresence(_ key: Data) throws {
        try write(key, account: deviceKeyAccount)
        guard try read(account: deviceKeyAccount, context: nil) == key else {
            throw LibraryKeyError.authenticationUnavailable
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: presenceDeviceKeyAccount,
        ] as CFDictionary)
    }

    func wrappedMasterKey() throws -> Data? {
        try read(account: masterKeyAccount, context: nil)
    }

    func store(wrappedMasterKey: Data) throws {
        try write(wrappedMasterKey, account: masterKeyAccount)
    }

    func recoveryBundle() throws -> RecoveryBundle? {
        guard let data = try read(account: recoveryAccount, context: nil) else { return nil }
        return try? JSONDecoder().decode(RecoveryBundle.self, from: data)
    }

    func store(recoveryBundle: RecoveryBundle) throws {
        try write(try JSONEncoder().encode(recoveryBundle), account: recoveryAccount)
    }

    func pendingMasterKey() throws -> Data? {
        try read(account: pendingMasterKeyAccount, context: nil)
    }

    func store(pendingMasterKey: Data) throws {
        try write(pendingMasterKey, account: pendingMasterKeyAccount)
    }

    func promotePendingMasterKey() throws {
        guard let pending = try pendingMasterKey() else { return }

        try store(wrappedMasterKey: pending)
        try discardPendingMasterKey()
    }

    func discardPendingMasterKey() throws {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pendingMasterKeyAccount,
        ] as CFDictionary)
    }

    private func readPresenceDeviceKey(context: LAContext) throws -> Data? {
        do {
            return try read(account: presenceDeviceKeyAccount, context: context)
        } catch LibraryKeyError.keychainFailure(let status) {
            throw Self.authenticationError(for: status) ?? LibraryKeyError.keychainFailure(status)
        }
    }

    private func read(account: String, context: LAContext?) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw LibraryKeyError.keychainFailure(status)
        }
    }

    private func write(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Self.authenticationError(for: status) ?? LibraryKeyError.keychainFailure(status)
        }
    }

    private static func authenticationError(for status: OSStatus) -> LibraryKeyError? {
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            .authenticationCancelled
        case errSecInteractionNotAllowed, errSecNotAvailable:
            .authenticationUnavailable
        case errSecMissingEntitlement:
            .missingKeychainPermission
        default:
            nil
        }
    }
}
