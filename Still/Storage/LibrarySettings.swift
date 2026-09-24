import Foundation

struct LibrarySettings: Codable, Equatable, Sendable {
    var ownerName: String?
    var rememberedVoices: Set<String>?

    var rememberedVoiceKeys: Set<String> {
        rememberedVoices ?? []
    }

    static func load(from url: URL, cipher: LibraryCipher) -> LibrarySettings {
        guard let sealed = try? Data(contentsOf: url),
              let data = try? cipher.open(sealed),
              let settings = try? JSONDecoder().decode(LibrarySettings.self, from: data)
        else { return LibrarySettings() }

        return settings
    }

    func save(to url: URL, cipher: LibraryCipher) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cipher.seal(try JSONEncoder().encode(self)).write(to: url, options: .atomic)
    }
}
