import CryptoKit
import Foundation
import Observation
import SwiftData
import Testing
@testable import Still

@MainActor
struct AutomaticRecordingTests {
    private let zoom = "us.zoom.xos"
    private let teams = "com.microsoft.teams2"
    private let slack = "com.tinyspeck.slackmacgap"

    @Test
    func savesTheRecordingWhenTheCallEnds() async throws {
        let clock = TestClock()
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom], clock: clock)
        automatic.startWatching()

        watcher.activate(zoom)
        await settle()
        #expect(coordinator.isRecording)
        #expect(automatic.triggeringApp?.name == "Zoom")

        clock.advance(by: AutomaticRecording.meetingLength)
        watcher.terminate(zoom)
        await settle(until: { coordinator.workflow == nil })

        #expect(!coordinator.isRecording)
        #expect(coordinator.workflow == nil)
        #expect(coordinator.phase == .idle)
        #expect(automatic.triggeredBy == nil)
    }

    @Test
    func aHelperProcessCountsAsItsApp() async throws {
        let (automatic, watcher, coordinator) = try await make(allowed: [slack])
        automatic.startWatching()

        watcher.activate("com.tinyspeck.slackmacgap.helper")
        await settle()

        #expect(coordinator.isRecording)
        #expect(automatic.triggeredBy == slack)
    }

    @Test
    func anAutomaticCallCapturesOnlyThatAppsSound() async throws {
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom])
        automatic.startWatching()

        watcher.activate(zoom)
        await settle()

        #expect(coordinator.audioTarget.scope == .apps([zoom]))
    }

    @Test
    func browsersAreLeftToTheExtension() {
        let browsers = ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "com.brave.Browser"]

        #expect(browsers.allSatisfy { CallApp.owner(of: $0) == nil })
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
    func switchingAnAppRedrawsTheList() async throws {
        let (automatic, _, _) = try await make(allowed: [])
        let app = try #require(automatic.apps.first { $0.bundleID == slack })
        let redrawn = Flag()
        withObservationTracking { _ = automatic.apps } onChange: { redrawn.raise() }

        automatic.setAllowed(true, for: app)

        #expect(redrawn.isRaised)
        #expect(automatic.apps.first { $0.bundleID == slack }?.isAllowed == true)
    }

    @Test
    func nothingStartsBeforeWatchingBegins() async throws {
        let (_, watcher, coordinator) = try await make(allowed: [zoom])

        watcher.activate(zoom)
        await settle()

        #expect(!coordinator.isRecording)
    }

    @Test
    func throwsAwayAShortMicrophoneCheck() async throws {
        let clock = TestClock()
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom], clock: clock)
        automatic.startWatching()

        watcher.activate(zoom)
        await settle()
        clock.advance(by: 12)
        watcher.terminate(zoom)
        await settle(until: { coordinator.workflow == nil })

        #expect(coordinator.library.recordings.isEmpty)
        #expect(automatic.discardedCheck == "Zoom")
        #expect(automatic.triggeredBy == nil)
    }

    @Test
    func aShortCallDuringACalendarMeetingIsKept() async throws {
        let clock = TestClock()
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom], clock: clock, evidence: true)
        automatic.startWatching()

        watcher.activate(zoom)
        await settle()
        clock.advance(by: 12)
        watcher.terminate(zoom)
        await settle(until: { !coordinator.library.recordings.isEmpty })

        #expect(coordinator.library.recordings.count == 1)
        #expect(automatic.discardedCheck == nil)
    }

    @Test
    func keepingAShortCallSavesIt() async throws {
        let clock = TestClock()
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom], clock: clock)
        automatic.startWatching()

        watcher.activate(zoom)
        await settle()
        automatic.keep()
        clock.advance(by: 5)
        watcher.terminate(zoom)
        await settle(until: { !coordinator.library.recordings.isEmpty })

        #expect(coordinator.library.recordings.count == 1)
    }

    private func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func endingACallWhilePreparingLeavesNoStrandedSheet() async throws {
        let gated = GatedAudioRecorder()
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom], gated: gated)
        automatic.startWatching()

        watcher.activate(zoom)
        await settle(until: { coordinator.phase == .preparing })
        watcher.terminate(zoom)
        await settle(until: { automatic.triggeredBy == nil })
        gated.release()
        await settle(until: { coordinator.workflow == nil })

        #expect(coordinator.phase == .idle)
        #expect(coordinator.workflow == nil)
        #expect(automatic.triggeredBy == nil)
        #expect(coordinator.library.recordings.isEmpty)
        #expect(automatic.discardedCheck == "Zoom")
    }

    @Test
    func automaticStartLogsTheCallAppInTheJournal() async throws {
        let scratch = try Scratch()
        let journal = DiagnosticJournal(
            fileURL: scratch.directory.appending(path: "journal.jsonl"),
            key: SymmetricKey(size: .bits256)
        )
        let (automatic, watcher, coordinator) = try await make(allowed: [zoom], journal: journal)
        automatic.startWatching()

        watcher.activate(zoom)
        await settle(until: { coordinator.isRecording })

        let started = try #require(try journal.entries().first { $0.code == .recordingStarted })
        #expect(started.detail == zoom)
    }

    private func make(
        allowed: [String],
        clock: TestClock = TestClock(),
        evidence: Bool = false,
        gated: GatedAudioRecorder? = nil,
        journal: DiagnosticJournal? = nil
    ) async throws -> (AutomaticRecording, FakeCallAppWatcher, RecordingCoordinator) {
        try await make(allowList: MemoryAllowList(allowed: Set(allowed)), clock: clock, evidence: evidence, gated: gated, journal: journal)
    }

    private func makeRecorderFactory(gated: GatedAudioRecorder?, audioRoot: URL) -> (SymmetricKey) -> AudioRecorder {
        if let gated {
            return { _ in gated }
        }
        return { key in WritingRecorder(root: audioRoot, cipher: LibraryCipher(key: key)) }
    }

    private func make(
        allowList: MemoryAllowList,
        clock: TestClock = TestClock(),
        evidence: Bool = false,
        gated: GatedAudioRecorder? = nil,
        journal: DiagnosticJournal? = nil
    ) async throws -> (AutomaticRecording, FakeCallAppWatcher, RecordingCoordinator) {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
                makeRecorder: makeRecorderFactory(gated: gated, audioRoot: audioRoot)
            ),
            journal: journal
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
            allowList: allowList,
            meetingEvidence: { _ in evidence },
            now: { clock.now }
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

final class Flag: @unchecked Sendable {
    private(set) var isRaised = false

    func raise() {
        isRaised = true
    }
}

final class TestClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)

    func advance(by seconds: TimeInterval) {
        now += seconds
    }
}
