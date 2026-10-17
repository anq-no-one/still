import Foundation
import Testing
@testable import Still

/// The share sheet runs Transferable export closures on a background queue.
/// This locks the off-main behavior that crashed Export in production.
struct MainActorExportTests {
    @Test
    func backgroundThreadRunsWorkOnMain() async throws {
        let ranOnMain = try await Task.detached(priority: .userInitiated) {
            try MainActorExport.run { Thread.isMainThread }
        }.value

        #expect(ranOnMain)
    }

    @Test
    func backgroundThreadReturnsTheWorkValue() async throws {
        let value = try await Task.detached(priority: .userInitiated) {
            try MainActorExport.run { 42 }
        }.value

        #expect(value == 42)
    }

    @Test
    @MainActor
    func mainThreadRunsInline() throws {
        #expect(Thread.isMainThread)
        let value = try MainActorExport.run { 7 }

        #expect(value == 7)
    }
}
