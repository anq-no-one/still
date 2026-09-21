import Foundation
import Observation

enum SetupStep: String, Codable, CaseIterable, Sendable {
    case privacy
    case microphone
    case transcription
    case pro
}

protocol SetupProgressStore: Sendable {
    func completedSteps() -> Set<SetupStep>
    func markCompleted(_ step: SetupStep)
    func reset()
}

@MainActor
protocol MicrophoneAccess: AnyObject {
    func requestAccess() async -> Bool
}

/// Walks a new user through privacy, permission, and the model download in that
/// order. Each step is recorded as it completes, so an interrupted setup opens
/// again at the step that still needs an answer.
@MainActor
@Observable
final class SetupFlow {
    private let store: SetupProgressStore
    private let microphone: MicrophoneAccess

    private(set) var completed: Set<SetupStep>
    private(set) var microphoneGranted = false

    /// Local-only is what Still does unless the user chooses otherwise. Sync and
    /// diagnostics are not part of setup because neither is on.
    var wantsPro = false

    init(store: SetupProgressStore, microphone: MicrophoneAccess) {
        self.store = store
        self.microphone = microphone
        completed = store.completedSteps()
    }

    var step: SetupStep? {
        SetupStep.allCases.first { !completed.contains($0) }
    }

    var isComplete: Bool {
        step == nil
    }

    func acknowledgePrivacy() {
        complete(.privacy)
    }

    func requestMicrophone() async {
        microphoneGranted = await microphone.requestAccess()
        complete(.microphone)
    }

    func skipMicrophone() {
        complete(.microphone)
    }

    func finishTranscription() {
        complete(.transcription)
    }

    func finishPro() {
        complete(.pro)
    }

    private func complete(_ step: SetupStep) {
        guard !completed.contains(step) else { return }

        completed.insert(step)
        store.markCompleted(step)
    }
}

struct UserDefaultsSetupProgressStore: SetupProgressStore, @unchecked Sendable {
    private let key = "still.setup.completed"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func completedSteps() -> Set<SetupStep> {
        Set((defaults.array(forKey: key) as? [String] ?? []).compactMap(SetupStep.init(rawValue:)))
    }

    func markCompleted(_ step: SetupStep) {
        var steps = completedSteps()
        steps.insert(step)
        defaults.set(steps.map(\.rawValue), forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }
}

@MainActor
final class SystemMicrophoneAccess: MicrophoneAccess {
    func requestAccess() async -> Bool {
        await MicrophonePermission.request()
    }
}
