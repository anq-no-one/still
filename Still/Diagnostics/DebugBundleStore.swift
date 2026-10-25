import Foundation

struct SavedBundle: Identifiable, Equatable, Sendable {
    let url: URL
    let bytes: Int
    let createdAt: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Where finished bundles stay until someone looks at them. On a Mac that is
/// a folder in Downloads, so a developer, or an agent on the same machine,
/// can open it without the app.
struct DebugBundleStore: Sendable {
    static let keeps = 10

    let directory: URL
    var keeps = Self.keeps

    static var bundlesDirectory: URL {
        #if os(macOS)
        URL.downloadsDirectory.appending(path: "Still Debug Bundles", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "Still/Debug Bundles", directoryHint: .isDirectory)
        #endif
    }

    static var bugReportsDirectory: URL {
        URL.downloadsDirectory.appending(path: "Still Bug Reports", directoryHint: .isDirectory)
    }

    @discardableResult
    func save(_ file: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: file.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        prune()
        return destination
    }

    @discardableResult
    func save(_ data: Data, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: name)
        try data.write(to: destination, options: .atomic)
        prune()
        return destination
    }

    func bundles() -> [SavedBundle] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return files
            .filter { $0.pathExtension == "zip" }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return SavedBundle(url: url, bytes: values?.fileSize ?? 0, createdAt: values?.creationDate ?? .distantPast)
            }
            .sorted { ($0.createdAt, $0.name) > ($1.createdAt, $1.name) }
    }

    func delete(_ bundle: SavedBundle) {
        try? FileManager.default.removeItem(at: bundle.url)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func prune() {
        for bundle in bundles().dropFirst(keeps) {
            delete(bundle)
        }
    }
}
