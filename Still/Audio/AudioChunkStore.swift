import Foundation

struct AudioManifest: Codable, Equatable, Sendable {
    var format: AudioFormat
    var chunkSeconds: TimeInterval
    var isComplete: Bool
}

struct InterruptedRecording: Equatable, Sendable {
    let id: UUID
    let directory: URL
    let duration: TimeInterval
}

final class AudioChunkWriter: @unchecked Sendable {
    private let directory: URL
    private let cipher: LibraryCipher
    private let format: AudioFormat
    private let chunkSeconds: TimeInterval
    private let lock = NSLock()

    private var pending = Data()
    private var nextIndex = 0

    init(
        directory: URL,
        cipher: LibraryCipher,
        format: AudioFormat = .transcription,
        chunkSeconds: TimeInterval = 5
    ) throws {
        self.directory = directory
        self.cipher = cipher
        self.format = format
        self.chunkSeconds = chunkSeconds

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeManifest(isComplete: false)
    }

    func append(_ pcm: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        pending.append(pcm)
        let chunkBytes = Int(chunkSeconds * TimeInterval(format.bytesPerSecond))
        while pending.count >= chunkBytes {
            try flush(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
        }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }

        if !pending.isEmpty {
            try flush(pending)
            pending.removeAll()
        }
        try writeManifest(isComplete: true)
    }

    private func flush(_ bytes: Data) throws {
        let sealed = try cipher.seal(Data(bytes))
        let staging = directory.appendingPathComponent(String(format: "%06d.partial", nextIndex))
        try sealed.write(to: staging, options: .atomic)
        try FileManager.default.moveItem(at: staging, to: AudioChunkStore.chunkURL(in: directory, index: nextIndex))
        nextIndex += 1
    }

    private func writeManifest(isComplete: Bool) throws {
        let manifest = AudioManifest(format: format, chunkSeconds: chunkSeconds, isComplete: isComplete)
        try cipher.seal(try JSONEncoder().encode(manifest))
            .write(to: AudioChunkStore.manifestURL(in: directory), options: .atomic)
    }
}

enum AudioChunkStore {
    static let chunkExtension = "chunk"

    static func directory(forRecording id: UUID, in root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest")
    }

    static func chunkURL(in directory: URL, index: Int) -> URL {
        directory.appendingPathComponent(String(format: "%06d.%@", index, chunkExtension))
    }

    static func manifest(in directory: URL, cipher: LibraryCipher) throws -> AudioManifest {
        let sealed = try Data(contentsOf: manifestURL(in: directory))
        return try JSONDecoder().decode(AudioManifest.self, from: try cipher.open(sealed))
    }

    /// Ordered chunks, stopping at the first one this key cannot authenticate. A killed
    /// process can only damage the newest chunk, so every earlier second stays readable.
    static func pcm(in directory: URL, cipher: LibraryCipher) throws -> Data {
        var pcm = Data()
        for url in try chunkURLs(in: directory) {
            guard let sealed = try? Data(contentsOf: url), let chunk = try? cipher.open(sealed) else { break }
            pcm.append(chunk)
        }
        return pcm
    }

    static func audio(in directory: URL, cipher: LibraryCipher) throws -> Data {
        WAVFile.data(
            pcm: try pcm(in: directory, cipher: cipher),
            format: try manifest(in: directory, cipher: cipher).format
        )
    }

    static func interruptedRecordings(in root: URL, cipher: LibraryCipher) throws -> [InterruptedRecording] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []

        return try directories.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  let manifest = try? manifest(in: directory, cipher: cipher),
                  !manifest.isComplete
            else { return nil }

            let pcm = try pcm(in: directory, cipher: cipher)
            guard !pcm.isEmpty else { return nil }

            return InterruptedRecording(
                id: id,
                directory: directory,
                duration: manifest.format.duration(ofBytes: pcm.count)
            )
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    static func markComplete(_ directory: URL, cipher: LibraryCipher) throws {
        var manifest = try manifest(in: directory, cipher: cipher)
        manifest.isComplete = true
        try cipher.seal(try JSONEncoder().encode(manifest))
            .write(to: manifestURL(in: directory), options: .atomic)
    }

    static func discard(_ directory: URL) throws {
        try FileManager.default.removeItem(at: directory)
    }

    private static func chunkURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == chunkExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
