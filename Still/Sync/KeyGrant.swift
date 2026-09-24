import CryptoKit
import Foundation

enum KeyGrant {
    struct Opened: Equatable {
        let secret: Data
        let sender: Data
    }

    private struct Envelope: Codable {
        let sender: Data
        let encapsulatedKey: Data
        let ciphertext: Data
    }

    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static let info = Data("still.key-grant".utf8)

    static func id(recipient: UUID, subject: UUID?) -> UUID {
        UUID(digestOf: Data("grant".utf8) + recipient.bytes + (subject?.bytes ?? Data("account".utf8)))
    }

    static func seal(
        _ secret: Data,
        subject: UUID?,
        to recipient: DeviceRecord,
        from sender: DeviceIdentity
    ) throws -> Data {
        var hpke = try HPKE.Sender(
            recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.publicKey),
            ciphersuite: suite,
            info: info,
            authenticatedBy: sender.agreementKey
        )
        let ciphertext = try hpke.seal(secret, authenticating: context(recipient: recipient.id, subject: subject))
        return try JSONEncoder().encode(
            Envelope(sender: sender.publicKey, encapsulatedKey: hpke.encapsulatedKey, ciphertext: ciphertext)
        )
    }

    static func open(_ payload: Data, subject: UUID?, as recipient: DeviceIdentity) throws -> Opened {
        let envelope = try JSONDecoder().decode(Envelope.self, from: payload)
        var hpke = try HPKE.Recipient(
            privateKey: recipient.agreementKey,
            ciphersuite: suite,
            info: info,
            encapsulatedKey: envelope.encapsulatedKey,
            authenticatedBy: Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.sender)
        )
        let secret = try hpke.open(envelope.ciphertext, authenticating: context(recipient: recipient.id, subject: subject))
        return Opened(secret: secret, sender: envelope.sender)
    }

    private static func context(recipient: UUID, subject: UUID?) -> Data {
        recipient.bytes + (subject?.bytes ?? Data("account".utf8))
    }
}
