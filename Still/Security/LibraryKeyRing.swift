import CryptoKit
import Foundation

protocol DeviceKeySource: Sendable {
    func deviceKey(reason: String) async throws -> SymmetricKey
    func wrappedMasterKey() throws -> Data?
    func store(wrappedMasterKey: Data) throws
    func recoveryBundle() throws -> RecoveryBundle?
    func store(recoveryBundle: RecoveryBundle) throws
    func rotateDeviceKey() throws -> SymmetricKey
}

struct LibraryKeyRing {
    private let source: DeviceKeySource

    init(source: DeviceKeySource) {
        self.source = source
    }

    func unlock(reason: String) async throws -> SymmetricKey {
        let deviceKey = try await source.deviceKey(reason: reason)
        let wrapping = LibraryCipher(key: deviceKey)

        if let wrapped = try source.wrappedMasterKey() {
            do {
                return SymmetricKey(data: try wrapping.open(wrapped))
            } catch {
                throw LibraryKeyError.unreadableKeyMaterial
            }
        }

        let master = SymmetricKey(size: .bits256)
        try source.store(wrappedMasterKey: try wrapping.seal(master.rawBytes))
        return master
    }

    /// Writing the code down is the only copy the user gets; Still keeps the
    /// wrapped key, never the code.
    func makeRecoveryCode(for master: SymmetricKey) throws -> RecoveryCode {
        let code = RecoveryCode.generate()
        var salt = Data(count: 32)
        salt.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        try source.store(
            recoveryBundle: RecoveryBundle(
                salt: salt,
                wrappedMasterKey: try LibraryCipher(key: code.derivedKey(salt: salt)).seal(master.rawBytes)
            )
        )
        return code
    }

    func restore(using code: RecoveryCode) throws -> SymmetricKey {
        guard let bundle = try source.recoveryBundle() else { throw LibraryKeyError.unrecoverable }
        guard let bytes = try? LibraryCipher(key: code.derivedKey(salt: bundle.salt)).open(bundle.wrappedMasterKey)
        else { throw LibraryKeyError.unrecoverable }

        return SymmetricKey(data: bytes)
    }

    /// Rotation gives a new master key and a device key that a revoked device
    /// never held, so nothing written afterwards opens with the old material.
    func rotate(reason: String) async throws -> SymmetricKey {
        let deviceKey = try source.rotateDeviceKey()
        let master = SymmetricKey(size: .bits256)
        try source.store(wrappedMasterKey: try LibraryCipher(key: deviceKey).seal(master.rawBytes))
        return master
    }
}

enum LibraryKeyError: LocalizedError, Equatable {
    case authenticationCancelled
    case authenticationUnavailable
    case unreadableKeyMaterial
    case unrecoverable
    case missingKeychainPermission
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .authenticationCancelled:
            "Still stays locked until you authenticate."
        case .authenticationUnavailable:
            "This device cannot authenticate you right now, so the Library stays locked."
        case .unreadableKeyMaterial:
            "Still cannot unlock the Library with the key stored on this device. Your recordings are untouched."
        case .unrecoverable:
            "That recovery code does not open this Library, and Still has no other way in. Encryption has no back door."
        case .missingKeychainPermission:
            "This build of Still is missing its keychain permission, so it cannot lock your Library. Reinstall a properly signed copy."
        case .keychainFailure(let status):
            "Still could not set up the lock for your Library (keychain status \(status))."
        }
    }
}
