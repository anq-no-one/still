import CryptoKit
import Foundation

struct LibraryCipher {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw LibraryCipherError.unreadable
        }
        return combined
    }

    func open(_ ciphertext: Data) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
        } catch {
            throw LibraryCipherError.unreadable
        }
    }
}

enum LibraryCipherError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "This content cannot be opened with the current key."
        }
    }
}

extension SymmetricKey {
    var rawBytes: Data {
        withUnsafeBytes { Data($0) }
    }
}
