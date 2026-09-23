import Foundation
import Testing
@testable import Still

@MainActor
struct SetupFlowTests {
    @Test
    func startsWithPrivacy() {
        let flow = makeFlow()

        #expect(flow.step == .privacy)
        #expect(!flow.isComplete)
    }

    @Test
    func walksEveryStepAndFinishesOnlyWhenEverythingIsReady() async {
        let permissions = FakeSetupPermissions()
        var modelReady = false
        let flow = makeFlow(permissions: permissions, isTranscriptionReady: { modelReady })

        flow.acknowledgePrivacy()
        #expect(flow.step == .microphone)

        await flow.requestMicrophone()
        #expect(flow.step == .systemAudio)

        flow.requestSystemAudio()
        #expect(flow.step == .transcription)

        modelReady = true
        flow.refresh()
        #expect(flow.isComplete)
    }

    @Test
    func aDeclinedMicrophoneKeepsSetupOpen() async {
        let permissions = FakeSetupPermissions(microphoneAnswer: .denied)
        let flow = makeFlow(permissions: permissions)
        flow.acknowledgePrivacy()

        await flow.requestMicrophone()

        #expect(flow.step == .microphone)
        #expect(flow.microphone == .denied)
    }

    @Test
    func aPermissionTakenAwayLaterReopensItsStep() async {
        let permissions = FakeSetupPermissions()
        let flow = makeFlow(permissions: permissions, isTranscriptionReady: { true })
        flow.acknowledgePrivacy()
        await flow.requestMicrophone()
        flow.requestSystemAudio()
        #expect(flow.isComplete)

        permissions.systemAudio = .denied
        flow.refresh()

        #expect(flow.step == .systemAudio)
    }

    @Test
    func iPhoneSetupHasNoSystemAudioStep() async {
        let flow = makeFlow(includesSystemAudio: false, isTranscriptionReady: { true })

        flow.acknowledgePrivacy()
        await flow.requestMicrophone()

        #expect(flow.isComplete)
    }

    @Test
    func privacyIsRememberedAcrossLaunches() {
        let store = MemorySetupStore()
        makeFlow(store: store).acknowledgePrivacy()

        #expect(makeFlow(store: store).step == .microphone)
    }

    private func makeFlow(
        store: MemorySetupStore = MemorySetupStore(),
        permissions: FakeSetupPermissions = FakeSetupPermissions(),
        includesSystemAudio: Bool = true,
        isTranscriptionReady: @escaping @MainActor () -> Bool = { false }
    ) -> SetupFlow {
        SetupFlow(
            store: store,
            permissions: permissions,
            includesSystemAudio: includesSystemAudio,
            isTranscriptionReady: isTranscriptionReady
        )
    }
}

final class MemorySetupStore: SetupProgressStore, @unchecked Sendable {
    private var steps: Set<SetupStep> = []

    func completedSteps() -> Set<SetupStep> { steps }
    func markCompleted(_ step: SetupStep) { steps.insert(step) }
    func reset() { steps.removeAll() }
}

@MainActor
final class FakeSetupPermissions: SetupPermissions {
    var microphone: PermissionState = .notAsked
    var systemAudio: PermissionState = .notAsked
    private let microphoneAnswer: PermissionState

    init(microphoneAnswer: PermissionState = .granted) {
        self.microphoneAnswer = microphoneAnswer
    }

    func requestMicrophone() async {
        microphone = microphoneAnswer
    }

    func requestSystemAudio() {
        systemAudio = .granted
    }
}
