import Foundation

enum AudioTrack: String, Codable, CaseIterable, Sendable {
    case microphone
    case system
}

struct AudioManifest: Codable, Equatable, Sendable {
    var format: AudioFormat
    var chunkSeconds: TimeInterval
    /// Seconds between the start of the Recording and this track's first sample.
    /// Both tracks replay on one timeline because each carries its own offset.
    var startOffset: TimeInterval
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
    private let startOffset: TimeInterval
    private let lock = NSLock()

    private var pending = Data()
    private var nextIndex = 0

    init(
        directory: URL,
        cipher: LibraryCipher,
        format: AudioFormat = .transcription,
        chunkSeconds: TimeInterval = 5,
        startOffset: TimeInterval = 0
    ) throws {
        self.directory = directory
        self.cipher = cipher
        self.format = format
        self.chunkSeconds = chunkSeconds
        self.startOffset = startOffset

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

    /// An atomic write lands the whole chunk or none of it, and replaces an
    /// existing chunk at that index rather than failing, so a re-import or a
    /// repeated sync writes the same slot cleanly.
    private func flush(_ bytes: Data) throws {
        try cipher.seal(Data(bytes))
            .write(to: AudioChunkStore.chunkURL(in: directory, index: nextIndex), options: .atomic)
        nextIndex += 1
    }

    private func writeManifest(isComplete: Bool) throws {
        let manifest = AudioManifest(
            format: format,
            chunkSeconds: chunkSeconds,
            startOffset: startOffset,
            isComplete: isComplete
        )
        try cipher.seal(try JSONEncoder().encode(manifest))
            .write(to: AudioChunkStore.manifestURL(in: directory), options: .atomic)
    }
}

enum AudioChunkStore {
    static let chunkExtension = "chunk"

    static func directory(forRecording id: UUID, in root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func trackDirectory(forRecording id: UUID, track: AudioTrack, in root: URL) -> URL {
        directory(forRecording: id, in: root).appendingPathComponent(track.rawValue, isDirectory: true)
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

    /// Ordered chunks, stopping at the first one this key cannot authenticate. A
    /// killed process can only damage the newest chunk, so every earlier second
    /// stays readable.
    static func pcm(in directory: URL, cipher: LibraryCipher) throws -> Data {
        var pcm = Data()
        for url in try chunkURLs(in: directory) {
            guard let sealed = try? Data(contentsOf: url), let chunk = try? cipher.open(sealed) else { break }
            pcm.append(chunk)
        }
        return pcm
    }

    static func tracks(forRecording id: UUID, in root: URL) -> [AudioTrack] {
        AudioTrack.allCases.filter { track in
            FileManager.default.fileExists(
                atPath: manifestURL(in: trackDirectory(forRecording: id, track: track, in: root)).path
            )
        }
    }

    static func audio(forRecording id: UUID, track: AudioTrack, in root: URL, cipher: LibraryCipher) throws -> Data {
        let directory = trackDirectory(forRecording: id, track: track, in: root)
        return WAVFile.data(
            pcm: try pcm(in: directory, cipher: cipher),
            format: try manifest(in: directory, cipher: cipher).format
        )
    }

    /// One stream for transcription and replay. Each track is placed on the
    /// shared timeline by its own offset, then summed with clipping guarded.
    static func mixed(forRecording id: UUID, in root: URL, cipher: LibraryCipher) throws -> (pcm: Data, format: AudioFormat) {
        let loaded: [(AudioManifest, Data)] = try tracks(forRecording: id, in: root).map { track in
            let directory = trackDirectory(forRecording: id, track: track, in: root)
            return (try manifest(in: directory, cipher: cipher), try pcm(in: directory, cipher: cipher))
        }

        guard let format = loaded.first?.0.format else { throw LibraryCipherError.unreadable }
        guard loaded.count > 1 else { return (loaded.first?.1 ?? Data(), format) }

        let placed = loaded.map { manifest, pcm -> (offset: Int, samples: [Int16]) in
            let frames = Int(manifest.startOffset * TimeInterval(manifest.format.sampleRate))
            return (frames * manifest.format.channels, samples(from: pcm))
        }

        let total = placed.map { $0.offset + $0.samples.count }.max() ?? 0
        var mix = [Int32](repeating: 0, count: total)
        for track in placed {
            for (index, sample) in track.samples.enumerated() {
                mix[track.offset + index] += Int32(sample)
            }
        }

        let clamped = mix.map { Int16(clamping: $0) }
        return (clamped.withUnsafeBufferPointer { Data(buffer: $0) }, format)
    }

    static func interruptedRecordings(in root: URL, cipher: LibraryCipher) throws -> [InterruptedRecording] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []

        return directories.compactMap { directory -> InterruptedRecording? in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }

            let tracks = tracks(forRecording: id, in: root)
            guard !tracks.isEmpty else { return nil }

            var unfinished = false
            var duration: TimeInterval = 0
            for track in tracks {
                let trackDirectory = trackDirectory(forRecording: id, track: track, in: root)
                guard let manifest = try? manifest(in: trackDirectory, cipher: cipher),
                      let pcm = try? pcm(in: trackDirectory, cipher: cipher)
                else { return nil }

                unfinished = unfinished || !manifest.isComplete
                duration = max(duration, manifest.startOffset + manifest.format.duration(ofBytes: pcm.count))
            }

            guard unfinished, duration > 0 else { return nil }
            return InterruptedRecording(id: id, directory: directory, duration: duration)
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    static func markComplete(forRecording id: UUID, in root: URL, cipher: LibraryCipher) throws {
        for track in tracks(forRecording: id, in: root) {
            let directory = trackDirectory(forRecording: id, track: track, in: root)
            var manifest = try manifest(in: directory, cipher: cipher)
            guard !manifest.isComplete else { continue }

            manifest.isComplete = true
            try cipher.seal(try JSONEncoder().encode(manifest))
                .write(to: manifestURL(in: directory), options: .atomic)
        }
    }

    static func chunkIndices(forRecording id: UUID, track: AudioTrack, in root: URL) -> [Int] {
        let directory = trackDirectory(forRecording: id, track: track, in: root)
        let urls = (try? chunkURLs(in: directory)) ?? []
        return urls.compactMap { Int($0.deletingPathExtension().lastPathComponent) }.sorted()
    }

    static func sealedChunk(forRecording id: UUID, track: AudioTrack, index: Int, in root: URL) throws -> Data {
        try Data(contentsOf: chunkURL(in: trackDirectory(forRecording: id, track: track, in: root), index: index))
    }

    static func sealedManifest(forRecording id: UUID, track: AudioTrack, in root: URL) throws -> Data {
        try Data(contentsOf: manifestURL(in: trackDirectory(forRecording: id, track: track, in: root)))
    }

    /// Writes are addressed by index, so a repeated or out-of-order delivery
    /// lands in the same place and changes nothing.
    static func writeSealed(_ data: Data, forRecording id: UUID, track: AudioTrack, part: AudioChunkPart, in root: URL) throws {
        let directory = trackDirectory(forRecording: id, track: track, in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        switch part {
        case .manifest:
            try data.write(to: manifestURL(in: directory), options: .atomic)
        case .chunk(let index):
            try data.write(to: chunkURL(in: directory, index: index), options: .atomic)
        }
    }

    static func discard(_ directory: URL) throws {
        try FileManager.default.removeItem(at: directory)
    }

    private static func samples(from pcm: Data) -> [Int16] {
        pcm.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
    }

    static func chunkURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == chunkExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
