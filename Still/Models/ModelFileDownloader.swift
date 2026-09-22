import CryptoKit
import Foundation

protocol ModelFileDownloader: Sendable {
    /// Appends to `destination` starting at its current size, so an interrupted
    /// download resumes instead of restarting.
    func download(from url: URL, resumingInto destination: URL) async throws
}

struct URLSessionModelFileDownloader: ModelFileDownloader {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(from url: URL, resumingInto destination: URL) async throws {
        let existing = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int) ?? 0
        var request = URLRequest(url: url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        // URLSession streams the body to its own file, which keeps a 483 MB
        // pack off the heap and out of a per-byte loop.
        let (downloaded, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ModelPackError.offline
        }

        // A server that ignored the range sent the whole file, so what is
        // already on disk has to go rather than be appended to.
        if http.statusCode != 206 {
            try? FileManager.default.removeItem(at: destination)
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }

        try Self.append(contentsOf: downloaded, to: destination)
    }

    private static func append(contentsOf source: URL, to destination: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        try writer.seekToEnd()

        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
    }
}

enum FileDigest {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
