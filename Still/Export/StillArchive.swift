import CryptoKit
import Foundation

struct ArchivedTrack: Codable, Equatable, Sendable {
    let track: AudioTrack
    let format: AudioFormat
    let startOffset: TimeInterval
    let pcm: Data
}

struct StillArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var recording: Recording
    var tracks: [ArchivedTrack]
}

enum StillArchiveError: LocalizedError, Equatable {
    case unreadable
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "This archive is damaged or was made with a different key."
        case .unsupportedVersion(let version):
            return "This archive was written by a newer version of Still (format \(version))."
        }
    }
}

/// An archive is one sealed blob. AES-GCM authenticates it, so a tampered or
/// truncated file fails to open rather than importing partial data.
enum StillArchiveCoder {
    static func seal(_ archive: StillArchive, with key: SymmetricKey) throws -> Data {
        try LibraryCipher(key: key).seal(try JSONEncoder().encode(archive))
    }

    static func open(_ data: Data, with key: SymmetricKey) throws -> StillArchive {
        guard let plaintext = try? LibraryCipher(key: key).open(data),
              let archive = try? JSONDecoder().decode(StillArchive.self, from: plaintext)
        else { throw StillArchiveError.unreadable }

        guard archive.version <= StillArchive.currentVersion else {
            throw StillArchiveError.unsupportedVersion(archive.version)
        }
        return archive
    }
}
