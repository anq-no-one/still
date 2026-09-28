import Carbon.HIToolbox
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct RecordingShortcutTests {
    private let commandShiftK = KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), key: "k")

    @Test
    func startsWithOptionCommandR() {
        let registrar = FakeHotKeyRegistrar()
        let shortcut = make(registrar: registrar)

        #expect(shortcut.combo == .standard)
        #expect(shortcut.combo?.displayText == "⌥⌘R")
        #expect(registrar.registered == .standard)
    }

    @Test
    func aValidShortcutReplacesTheOldOneAndSurvivesRelaunch() {
        let store = MemoryShortcutStore()
        let registrar = FakeHotKeyRegistrar()
        let shortcut = make(registrar: registrar, store: store)

        #expect(shortcut.change(to: commandShiftK))
        #expect(registrar.registered == commandShiftK)

        let relaunchedRegistrar = FakeHotKeyRegistrar()
        let relaunched = make(registrar: relaunchedRegistrar, store: store)
        #expect(relaunched.combo == commandShiftK)
        #expect(relaunchedRegistrar.registered == commandShiftK)
    }

    @Test
    func aKeyWithoutCommandOptionOrControlIsRejected() {
        let shortcut = make()

        #expect(!shortcut.change(to: KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(shiftKey), key: "k")))
        #expect(shortcut.problem == .needsModifier)
        #expect(shortcut.combo == .standard)
    }

    @Test
    func aShortcutMacOSUsesIsRejected() {
        let spotlight = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), key: " ")
        let shortcut = make(system: FakeSystemShortcuts(reserved: [spotlight]))

        #expect(!shortcut.change(to: spotlight))
        #expect(shortcut.problem == .reservedBySystem)
        #expect(shortcut.combo == .standard)
    }

    @Test
    func aShortcutAnotherAppHoldsIsRejectedAndTheOldOneKeepsWorking() {
        let registrar = FakeHotKeyRegistrar()
        let shortcut = make(registrar: registrar)
        registrar.taken = [commandShiftK]

        #expect(!shortcut.change(to: commandShiftK))
        #expect(shortcut.problem == .takenByAnotherApp)
        #expect(shortcut.combo == .standard)
        #expect(registrar.registered == .standard)
    }

    @Test
    func reloadingPicksUpAShortcutSavedElsewhere() {
        let store = MemoryShortcutStore()
        let registrar = FakeHotKeyRegistrar()
        let shortcut = make(registrar: registrar, store: store)

        store.save(commandShiftK)
        shortcut.reload()

        #expect(shortcut.combo == commandShiftK)
        #expect(registrar.registered == commandShiftK)
    }

    @Test
    func pressingTheShortcutRunsTheAction() {
        let registrar = FakeHotKeyRegistrar()
        var pressed = 0
        _ = RecordingShortcut(registrar: registrar, system: FakeSystemShortcuts(), store: MemoryShortcutStore()) {
            pressed += 1
        }

        registrar.press()

        #expect(pressed == 1)
    }

    private func make(
        registrar: FakeHotKeyRegistrar = FakeHotKeyRegistrar(),
        system: FakeSystemShortcuts = FakeSystemShortcuts(),
        store: MemoryShortcutStore = MemoryShortcutStore()
    ) -> RecordingShortcut {
        RecordingShortcut(registrar: registrar, system: system, store: store) {}
    }
}

@MainActor
struct PreparingCaptureTests {
    @Test
    func stoppingWhilePreparingConvergesToIdleInsteadOfStranding() async throws {
        let gated = GatedAudioRecorder()
        let coordinator = try await makeCoordinator(recorder: gated)

        let started = Task { await coordinator.start() }
        await settle(until: { coordinator.phase == .preparing })
        await coordinator.stopAndSave()
        gated.release()
        await started.value

        #expect(coordinator.phase == .idle)
        #expect(coordinator.workflow == nil)
        #expect(gated.discardedCount >= 1)

        gated.gatesStart = false
        await coordinator.start()

        #expect(coordinator.isRecording)
        await coordinator.cancel()
    }

    @Test
    func cancellingWhilePreparingConvergesToIdleInsteadOfStranding() async throws {
        let gated = GatedAudioRecorder()
        let coordinator = try await makeCoordinator(recorder: gated)

        let started = Task { await coordinator.start() }
        await settle(until: { coordinator.phase == .preparing })
        await coordinator.cancel()
        gated.release()
        await started.value

        #expect(coordinator.phase == .idle)
        #expect(coordinator.workflow == nil)
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeCoordinator(recorder: GatedAudioRecorder) async throws -> RecordingCoordinator {
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
                makeRecorder: { _ in recorder }
            )
        )
        await library.unlock()
        return RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { FakeTranscriptionSession() },
            makeFinalTranscription: { FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600) }
        )
    }
}

@MainActor
struct LaunchAtLoginTests {
    @Test
    func staysOffUntilEnabledAndCanBeTurnedOffAgain() {
        let service = FakeLoginItem()
        let login = LaunchAtLogin(service: service)
        #expect(!login.isEnabled)

        login.set(true)
        #expect(login.isEnabled)

        login.set(false)
        #expect(!login.isEnabled)
    }

    @Test
    func aRefusedRegistrationSaysWhy() {
        let service = FakeLoginItem()
        service.failure = CocoaError(.featureUnsupported)
        let login = LaunchAtLogin(service: service)

        login.set(true)

        #expect(!login.isEnabled)
        #expect(login.problem?.isEmpty == false)
    }
}

@MainActor
struct MediaPlaybackHintTests {
    @Test
    func namesAppsPlayingSoundButNotCallsOrStill() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let source = FakeActivitySource(activity: [
            AudioProcessActivity(bundleID: "com.spotify.client", usesMicrophone: false, playsAudio: true),
            AudioProcessActivity(bundleID: "us.zoom.xos", usesMicrophone: false, playsAudio: true),
            AudioProcessActivity(bundleID: "com.andrii.still", usesMicrophone: false, playsAudio: true),
            AudioProcessActivity(bundleID: "com.apple.Music", usesMicrophone: false, playsAudio: false),
        ])
        let hint = MediaPlaybackHint(source: source, settings: defaults, ownBundleID: "com.andrii.still")

        hint.check()

        #expect(hint.playingBundleIDs == ["com.spotify.client"])
    }

    @Test
    func turningTheWarningOffKeepsItQuiet() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let source = FakeActivitySource(activity: [
            AudioProcessActivity(bundleID: "com.spotify.client", usesMicrophone: false, playsAudio: true),
        ])
        let hint = MediaPlaybackHint(source: source, settings: defaults, ownBundleID: "com.andrii.still")

        hint.turnOff()
        hint.check()

        #expect(hint.playingBundleIDs.isEmpty)
    }
}

@MainActor
final class FakeHotKeyRegistrar: HotKeyRegistrar {
    var taken: [KeyCombo] = []
    private(set) var registered: KeyCombo?
    private var action: @MainActor () -> Void = {}

    func register(_ combo: KeyCombo, action: @escaping @MainActor () -> Void) -> Bool {
        guard !taken.contains(combo) else { return false }
        registered = combo
        self.action = action
        return true
    }

    func unregister() {
        registered = nil
    }

    func press() {
        action()
    }
}

struct FakeSystemShortcuts: SystemShortcutSource {
    var reserved: [KeyCombo] = []

    func reservedCombos() -> [KeyCombo] { reserved }
}

final class MemoryShortcutStore: ShortcutStore, @unchecked Sendable {
    private var combo: KeyCombo?

    func load() -> KeyCombo? { combo }
    func save(_ combo: KeyCombo) { self.combo = combo }
}

@MainActor
final class FakeLoginItem: LoginItemService {
    var failure: Error?
    private(set) var isEnabled = false

    func enable() throws {
        if let failure { throw failure }
        isEnabled = true
    }

    func disable() throws {
        isEnabled = false
    }
}

struct FakeActivitySource: AudioActivitySource {
    let activity: [AudioProcessActivity]

    func currentActivity() -> [AudioProcessActivity] { activity }
}
