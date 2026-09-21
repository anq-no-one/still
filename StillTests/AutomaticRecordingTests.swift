import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct AutomaticRecordingTests {
    private let zoom = "us.zoom.xos"
    private let teams = "com.microsoft.teams2"

    @Test
    func recordsOnlyForAnAppTheUserAllowed() async throws {
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom])
        automatic.startWatching()

        watcher.activate(teams)
        await Task.yield()

        #expect(!coordinator.isRecording)

        watcher.activate(zoom)
        await Task.yield()
        await Task.yield()

        #expect(coordinator.isRecording)
        #expect(automatic.triggeredBy == zoom)
    }

    @Test
    func comingBackToTheSameAppDoesNotStartASecondRecording() async throws {
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom])
        automatic.startWatching()

        watcher.activate(zoom)
        await settle()
        let first = coordinator.workflow

        watcher.activate(zoom)
        await settle()

        #expect(coordinator.workflow === first)
    }

    @Test
    func aFalseStartCanBeThrownAwayImmediately() async throws {
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom])
        automatic.startWatching()
        watcher.activate(zoom)
        await settle()

        await automatic.discardAutomaticRecording()

        #expect(!coordinator.isRecording)
        #expect(automatic.triggeredBy == nil)
    }

    @Test
    func switchingAnAppOffStopsFutureStarts() async throws {
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom])
        automatic.startWatching()
        let app = try #require(automatic.apps.first { $0.bundleID == zoom })

        automatic.setAllowed(false, for: app)
        watcher.activate(zoom)
        await settle()

        #expect(!coordinator.isRecording)
    }

    @Test
    func nothingStartsBeforeWatchingBegins() async throws {
        let (_, watcher, coordinator) = try await make(allowed: [zoom])

        watcher.activate(zoom)
        await settle()

        #expect(!coordinator.isRecording)
    }

    private func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }

    private func make(
        allowed: [String]
    ) async throws -> (AutomaticRecording, FakeCallAppWatcher, RecordingCoordinator) {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let audioRoot = try Scratch().directory
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { key in
                    MainActor.assumeIsolated { WritingRecorder(root: audioRoot, cipher: LibraryCipher(key: key)) }
                }
            )
        )
        await library.unlock()

        let coordinator = RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { FakeTranscriptionSession() },
            makeFinalTranscription: { FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600) }
        )
        let watcher = FakeCallAppWatcher()
        let automatic = AutomaticRecording(
            coordinator: coordinator,
            watcher: watcher,
            allowList: MemoryAllowList(allowed: Set(allowed))
        )
        return (automatic, watcher, coordinator)
    }
}

@MainActor
final class FakeCallAppWatcher: CallAppWatcher {
    private var onActivate: (@MainActor (String) -> Void)?
    private var onDeactivate: (@MainActor (String) -> Void)?

    func start(
        onActivate: @escaping @MainActor (String) -> Void,
        onDeactivate: @escaping @MainActor (String) -> Void
    ) {
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
    }

    func stop() {
        onActivate = nil
        onDeactivate = nil
    }

    func activate(_ bundleID: String) {
        onActivate?(bundleID)
    }

    func terminate(_ bundleID: String) {
        onDeactivate?(bundleID)
    }
}

final class MemoryAllowList: CallAppAllowList, @unchecked Sendable {
    private var allowed: Set<String>

    init(allowed: Set<String>) {
        self.allowed = allowed
    }

    func apps() -> [CallApp] {
        CallApp.known.map { CallApp(bundleID: $0.bundleID, name: $0.name, isAllowed: allowed.contains($0.bundleID)) }
    }

    func setAllowed(_ isAllowed: Bool, forBundleID bundleID: String) {
        if isAllowed {
            allowed.insert(bundleID)
        } else {
            allowed.remove(bundleID)
        }
    }
}
