import CryptoKit
import Foundation
import Testing
@testable import Still

struct LibraryCipherTests {
    @Test
    func roundTripsContent() throws {
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        let plaintext = Data("Decisions and owners".utf8)

        let sealed = try cipher.seal(plaintext)

        #expect(sealed != plaintext)
        #expect(try cipher.open(sealed) == plaintext)
    }

    @Test
    func refusesTheWrongKey() throws {
        let sealed = try LibraryCipher(key: SymmetricKey(size: .bits256)).seal(Data("secret".utf8))
        let other = LibraryCipher(key: SymmetricKey(size: .bits256))

        #expect(throws: LibraryCipherError.unreadable) {
            try other.open(sealed)
        }
    }

    @Test
    func refusesCorruptedCiphertext() throws {
        let cipher = LibraryCipher(key: SymmetricKey(size: .bits256))
        var sealed = try cipher.seal(Data("secret".utf8))
        sealed[sealed.count - 1] ^= 0xFF

        #expect(throws: LibraryCipherError.unreadable) {
            try cipher.open(sealed)
        }
    }
}

struct LibraryKeyRingTests {
    @Test
    func createsAndWrapsTheMasterKeyOnce() async throws {
        let source = FakeDeviceKeySource()
        let keyRing = LibraryKeyRing(source: source)

        let first = try await keyRing.unlock(reason: "test")
        let second = try await keyRing.unlock(reason: "test")

        #expect(first == second)
        #expect(source.storedWrappedKey != nil)
        #expect(source.storedWrappedKey != first.rawBytes)
    }

    @Test
    func failsWhenAuthenticationIsCancelled() async {
        let source = FakeDeviceKeySource()
        source.deviceKeyError = LibraryKeyError.authenticationCancelled

        await #expect(throws: LibraryKeyError.authenticationCancelled) {
            try await LibraryKeyRing(source: source).unlock(reason: "test")
        }
    }

    @Test
    func failsWhenBiometricsAreUnavailable() async {
        let source = FakeDeviceKeySource()
        source.deviceKeyError = LibraryKeyError.authenticationUnavailable

        await #expect(throws: LibraryKeyError.authenticationUnavailable) {
            try await LibraryKeyRing(source: source).unlock(reason: "test")
        }
    }

    @Test
    func keepsWrappedKeyWhenTheDeviceKeyNoLongerOpensIt() async throws {
        let source = FakeDeviceKeySource()
        _ = try await LibraryKeyRing(source: source).unlock(reason: "test")
        let stored = source.storedWrappedKey
        source.deviceKey = SymmetricKey(size: .bits256)

        await #expect(throws: LibraryKeyError.unreadableKeyMaterial) {
            try await LibraryKeyRing(source: source).unlock(reason: "test")
        }
        #expect(source.storedWrappedKey == stored)
    }
}

final class FakeDeviceKeySource: DeviceKeySource, @unchecked Sendable {
    var deviceKey = SymmetricKey(size: .bits256)
    var deviceKeyError: Error?
    private(set) var storedWrappedKey: Data?

    func deviceKey(reason: String) async throws -> SymmetricKey {
        if let deviceKeyError { throw deviceKeyError }
        return deviceKey
    }

    func wrappedMasterKey() throws -> Data? {
        storedWrappedKey
    }

    func store(wrappedMasterKey: Data) throws {
        storedWrappedKey = wrappedMasterKey
    }

    private(set) var storedRecovery: RecoveryBundle?

    func recoveryBundle() throws -> RecoveryBundle? {
        storedRecovery
    }

    func store(recoveryBundle: RecoveryBundle) throws {
        storedRecovery = recoveryBundle
    }

    func rotateDeviceKey() throws -> SymmetricKey {
        deviceKey = SymmetricKey(size: .bits256)
        return deviceKey
    }
}

struct KeychainStatusMessageTests {
    @Test
    func aMissingEntitlementBlamesTheBuildNotTheDevice() {
        let message = LibraryKeyError.missingKeychainPermission.localizedDescription

        #expect(message.contains("keychain permission"))
        #expect(!message.contains("-34018"))
    }

    @Test
    func anUnmappedStatusStillCarriesItsCodeForSupport() {
        #expect(LibraryKeyError.keychainFailure(-25300).localizedDescription.contains("-25300"))
    }

    @Test
    func eachFailureReadsAsSomethingTheUserCanActmOn() {
        let messages = [
            LibraryKeyError.authenticationCancelled,
            .authenticationUnavailable,
            .unreadableKeyMaterial,
            .unrecoverable,
            .missingKeychainPermission,
        ].map(\.localizedDescription)

        #expect(messages.allSatisfy { $0.hasSuffix(".") })
        #expect(messages.allSatisfy { $0.count > 30 })
    }
}
