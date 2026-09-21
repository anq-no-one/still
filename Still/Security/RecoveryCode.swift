import CryptoKit
import Foundation

/// A code the user writes down once. It is never stored in readable form; only
/// the master key wrapped under it is kept, so losing the code means the
/// wrapped copy stays shut.
struct RecoveryCode: Equatable, Sendable {
    static let groupCount = 6
    static let groupLength = 5
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    let text: String

    init(text: String) {
        self.text = RecoveryCode.normalize(text)
    }

    static func generate() -> RecoveryCode {
        var characters: [Character] = []
        for _ in 0..<(groupCount * groupLength) {
            characters.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }

        let groups = stride(from: 0, to: characters.count, by: groupLength).map {
            String(characters[$0..<min($0 + groupLength, characters.count)])
        }
        return RecoveryCode(text: groups.joined(separator: "-"))
    }

    var formatted: String {
        stride(from: 0, to: text.count, by: Self.groupLength)
            .map { offset in
                let start = text.index(text.startIndex, offsetBy: offset)
                let end = text.index(start, offsetBy: min(Self.groupLength, text.count - offset))
                return String(text[start..<end])
            }
            .joined(separator: "-")
    }

    var isWellFormed: Bool {
        text.count == Self.groupCount * Self.groupLength
            && text.allSatisfy { Self.alphabet.contains($0) }
    }

    func derivedKey(salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(text.utf8)),
            salt: salt,
            info: Data("still.library.recovery".utf8),
            outputByteCount: 32
        )
    }

    private static func normalize(_ text: String) -> String {
        text.uppercased().filter { alphabet.contains($0) }
    }
}

struct RecoveryBundle: Codable, Equatable, Sendable {
    let salt: Data
    let wrappedMasterKey: Data
}
