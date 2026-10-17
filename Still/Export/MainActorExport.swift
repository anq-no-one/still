import Foundation

enum MainActorExport {
    static func run<T: Sendable>(_ work: @MainActor () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(work)
        }
        return try DispatchQueue.main.sync {
            try MainActor.assumeIsolated(work)
        }
    }
}
