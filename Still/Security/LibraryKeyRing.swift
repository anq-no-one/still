import CryptoKit
import Foundation

protocol DeviceKeySource: Sendable {
    func deviceKey(reason: String) async throws -> SymmetricKey
    func wrappedMasterKey() throws -> Data?
    func store(wrappedMasterKey: Data) throws
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
}

enum LibraryKeyError: LocalizedError, Equatable {
    case authenticationCancelled
    case authenticationUnavailable
    case unreadableKeyMaterial
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .authenticationCancelled:
            "Still stays locked until you authenticate."
        case .authenticationUnavailable:
            "This device cannot authenticate you right now, so the Library stays locked."
        case .unreadableKeyMaterial:
            "Still cannot unlock the Library with the key stored on this device. Your recordings are untouched."
        case .keychainFailure:
            "Still cannot reach the device keychain, so the Library stays locked."
        }
    }
}
