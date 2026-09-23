import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct AutomaticRecordingTests {
    private let zoom = "us.zoom.xos"
    private let teams = "com.microsoft.teams2"
    private let chrome = "com.google.Chrome"

    @Test
    func savesTheRecordingWhenTheCallEnds() async throws {
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom])
        automatic.startWatching()

        watcher.activate(zoom)
        await settle()
        #expect(coordinator.isRecording)

        watcher.terminate(zoom)
        await settle(until: { coordinator.workflow == nil })

        #expect(!coordinator.isRecording)
        #expect(coordinator.workflow == nil)
        #expect(coordinator.phase == .idle)
        #expect(automatic.triggeredBy == nil)
    }

    @Test
    func aBrowserHelperProcessCountsAsTheBrowser() async throws {
        let (automatic, watcher, coordinator) = try await make(allowed: [chrome])
        automatic.startWatching()

        watcher.activate("com.google.Chrome.helper")
        await settle()

        #expect(coordinator.isRecording)
        #expect(automatic.triggeredBy == chrome)
    }

    @Test
    func keepsWatchingAfterRelaunch() async throws {
        let allowList = MemoryAllowList(allowed: [zoom])
        let (first, _, coordinator) = try await make(allowList: allowList)
        first.startWatching()

        let relaunched = AutomaticRecording(coordinator: coordinator, watcher: FakeCallAppWatcher(), allowList: allowList)

        #expect(relaunched.isWatching)
    }

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

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func make(
        allowed: [String]
    ) async throws -> (AutomaticRecording, FakeCallAppWatcher, RecordingCoordinator) {
        try await make(allowList: MemoryAllowList(allowed: Set(allowed)))
    }

    private func make(
        allowList: MemoryAllowList
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
            allowList: allowList
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
    var watches = false

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

    func setWatching(_ watching: Bool) {
        watches = watching
    }
}
