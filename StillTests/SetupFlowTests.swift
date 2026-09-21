import Foundation
import Testing
@testable import Still

@MainActor
struct SetupFlowTests {
    @Test
    func startsWithPrivacyAndNeedsNoAccount() {
        let flow = SetupFlow(store: MemorySetupStore(), microphone: FakeMicrophoneAccess(granted: true))

        #expect(flow.step == .privacy)
        #expect(!flow.isComplete)
        #expect(!flow.wantsPro)
    }

    @Test
    func walksEveryStepOnceAndFinishes() async {
        let flow = SetupFlow(store: MemorySetupStore(), microphone: FakeMicrophoneAccess(granted: true))

        flow.acknowledgePrivacy()
        #expect(flow.step == .microphone)

        await flow.requestMicrophone()
        #expect(flow.microphoneGranted)
        #expect(flow.step == .transcription)

        flow.finishTranscription()
        #expect(flow.step == .pro)

        flow.finishPro()
        #expect(flow.isComplete)
    }

    @Test
    func resumesAtTheStepThatStillNeedsAnAnswer() async {
        let store = MemorySetupStore()
        let first = SetupFlow(store: store, microphone: FakeMicrophoneAccess(granted: true))
        first.acknowledgePrivacy()
        await first.requestMicrophone()

        let resumed = SetupFlow(store: store, microphone: FakeMicrophoneAccess(granted: true))

        #expect(resumed.step == .transcription)
    }

    @Test
    func nothingHappensBeforeItsStep() async {
        let microphone = FakeMicrophoneAccess(granted: true)
        let flow = SetupFlow(store: MemorySetupStore(), microphone: microphone)

        flow.acknowledgePrivacy()

        #expect(microphone.requests == 0)

        await flow.requestMicrophone()

        #expect(microphone.requests == 1)
    }

    @Test
    func aDeclinedMicrophoneStillMovesOn() async {
        let flow = SetupFlow(store: MemorySetupStore(), microphone: FakeMicrophoneAccess(granted: false))
        flow.acknowledgePrivacy()

        await flow.requestMicrophone()

        #expect(!flow.microphoneGranted)
        #expect(flow.step == .transcription)
    }

    @Test
    func skippingTheMicrophoneDoesNotAsk() {
        let microphone = FakeMicrophoneAccess(granted: true)
        let flow = SetupFlow(store: MemorySetupStore(), microphone: microphone)
        flow.acknowledgePrivacy()

        flow.skipMicrophone()

        #expect(microphone.requests == 0)
        #expect(flow.step == .transcription)
    }
}

final class MemorySetupStore: SetupProgressStore, @unchecked Sendable {
    private var steps: Set<SetupStep> = []

    func completedSteps() -> Set<SetupStep> { steps }
    func markCompleted(_ step: SetupStep) { steps.insert(step) }
    func reset() { steps.removeAll() }
}

@MainActor
final class FakeMicrophoneAccess: MicrophoneAccess {
    private let granted: Bool
    private(set) var requests = 0

    init(granted: Bool) {
        self.granted = granted
    }

    func requestAccess() async -> Bool {
        requests += 1
        return granted
    }
}
