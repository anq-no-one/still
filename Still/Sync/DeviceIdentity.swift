import CommonCrypto
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum DeviceKind: String, Codable, Sendable {
    case mac
    case iphone
    case ipad

    @MainActor
    static var current: DeviceKind {
        #if os(macOS)
        .mac
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
        #endif
    }

    var title: String {
        switch self {
        case .mac: String(localized: "Mac")
        case .iphone: String(localized: "iPhone")
        case .ipad: String(localized: "iPad")
        }
    }
}

struct DeviceIdentity: Sendable {
    let id: UUID
    let kind: DeviceKind
    let agreementKey: Curve25519.KeyAgreement.PrivateKey

    init(agreementKey: Curve25519.KeyAgreement.PrivateKey = .init(), kind: DeviceKind = .mac, id: UUID? = nil) {
        self.agreementKey = agreementKey
        self.kind = kind
        self.id = id ?? UUID(digestOf: agreementKey.publicKey.rawRepresentation)
    }

    var publicKey: Data {
        agreementKey.publicKey.rawRepresentation
    }
}

struct DeviceRecord: Codable, Equatable, Sendable {
    let id: UUID
    let kind: DeviceKind
    let publicKey: Data
    let accountID: UUID
    let accountCreatedAt: Date
    let requestedScopes: Set<UUID>
    let heldScopes: Set<UUID>

    func isNewer(thanAccount accountID: UUID, createdAt: Date) -> Bool {
        accountCreatedAt != createdAt
            ? accountCreatedAt > createdAt
            : self.accountID.uuidString > accountID.uuidString
    }
}

enum VerificationCode {
    static let rounds: UInt32 = 400_000

    static func between(_ first: Data, _ second: Data) -> String {
        let ordered = [first, second].sorted { $0.lexicographicallyPrecedes($1) }
        let digest = stretch(ordered[0] + ordered[1])
        let number = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000_000
        let digits = Array(String(format: "%09llu", number))
        return stride(from: 0, to: digits.count, by: 3).map { String(digits[$0..<$0 + 3]) }.joined(separator: " ")
    }

    private static func stretch(_ keys: Data) -> Data {
        let salt = Data("still.join-code".utf8)
        var output = Data(count: 32)
        let status = output.withUnsafeMutableBytes { outputBytes in
            keys.withUnsafeBytes { keyBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        keyBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        keys.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        outputBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return status == kCCSuccess ? output : Data(SHA256.hash(data: keys))
    }
}

extension UUID {
    init(digestOf data: Data) {
        let bytes = Array(SHA256.hash(data: data).prefix(16))
        self = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    var bytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
