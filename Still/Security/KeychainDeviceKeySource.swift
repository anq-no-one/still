import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct KeychainDeviceKeySource: DeviceKeySource {
    private let service: String
    private let deviceKeyAccount = "library-device-key"
    private let masterKeyAccount = "library-master-key"
    private let recoveryAccount = "library-recovery"

    init(service: String = "com.andrii.still.library") {
        self.service = service
    }

    func deviceKey(reason: String) async throws -> SymmetricKey {
        let context = LAContext()
        context.localizedReason = reason

        if let existing = try readDeviceKey(context: context) {
            return SymmetricKey(data: existing)
        }

        let key = SymmetricKey(size: .bits256)
        try writeDeviceKey(key.rawBytes)
        return key
    }

    func wrappedMasterKey() throws -> Data? {
        try read(account: masterKeyAccount, context: nil)
    }

    func store(wrappedMasterKey: Data) throws {
        try write(wrappedMasterKey, account: masterKeyAccount, accessControl: nil)
    }

    func recoveryBundle() throws -> RecoveryBundle? {
        guard let data = try read(account: recoveryAccount, context: nil) else { return nil }
        return try? JSONDecoder().decode(RecoveryBundle.self, from: data)
    }

    func store(recoveryBundle: RecoveryBundle) throws {
        try write(try JSONEncoder().encode(recoveryBundle), account: recoveryAccount, accessControl: nil)
    }

    func rotateDeviceKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        try writeDeviceKey(key.rawBytes)
        return key
    }

    private func readDeviceKey(context: LAContext) throws -> Data? {
        do {
            return try read(account: deviceKeyAccount, context: context)
        } catch LibraryKeyError.keychainFailure(let status) {
            throw Self.authenticationError(for: status) ?? LibraryKeyError.keychainFailure(status)
        }
    }

    private func writeDeviceKey(_ data: Data) throws {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw LibraryKeyError.authenticationUnavailable
        }

        try write(data, account: deviceKeyAccount, accessControl: control)
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

    private func write(_ data: Data, account: String, accessControl: SecAccessControl?) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        if let accessControl {
            attributes[kSecAttrAccessControl as String] = accessControl
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LibraryKeyError.keychainFailure(status)
        }
    }

    private static func authenticationError(for status: OSStatus) -> LibraryKeyError? {
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            .authenticationCancelled
        case errSecInteractionNotAllowed, errSecNotAvailable:
            .authenticationUnavailable
        default:
            nil
        }
    }
}
