import Foundation

struct ImportedFile: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case audio
        case video
    }

    let name: String
    let kind: Kind
}
