import Foundation

enum MeetingTileStore {
    static let directoryName = "tiles"
    static let frameExtension = "tile"

    static func directory(forRecording id: UUID, in root: URL) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
    }

    static func save(_ png: Data, offset: TimeInterval, recordingID: UUID, root: URL, cipher: LibraryCipher) throws {
        let directory = directory(forRecording: recordingID, in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sealed = try cipher.seal(png)
        try sealed.write(to: directory.appending(path: fileName(for: offset)), options: .atomic)
    }

    static func frames(recordingID: UUID, root: URL, cipher: LibraryCipher) throws -> [(offset: TimeInterval, png: Data)] {
        let directory = directory(forRecording: recordingID, in: root)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var frames: [(TimeInterval, Data)] = []
        for file in files where file.pathExtension == frameExtension {
            guard let offset = offset(from: file) else { continue }
            let sealed = try Data(contentsOf: file)
            frames.append((offset, try cipher.open(sealed)))
        }
        return frames.sorted { $0.0 < $1.0 }
    }

    static func discard(recordingID: UUID, root: URL) {
        try? FileManager.default.removeItem(at: directory(forRecording: recordingID, in: root))
    }

    static func discardLeftovers(in root: URL) {
        guard let recordings = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for recording in recordings where UUID(uuidString: recording.lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: recording.appending(path: directoryName, directoryHint: .isDirectory))
        }
    }

    private static func fileName(for offset: TimeInterval) -> String {
        String(format: "%010.2f", max(0, offset)) + ".\(frameExtension)"
    }

    private static func offset(from file: URL) -> TimeInterval? {
        TimeInterval(file.deletingPathExtension().lastPathComponent)
    }
}
