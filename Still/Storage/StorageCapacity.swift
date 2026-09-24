import Foundation

enum StorageCapacity {
    static func available(at url: URL) -> Int64? {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { return nil }
            candidate = parent
        }
        return try? candidate
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}
