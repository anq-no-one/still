import Foundation
import Observation

enum SetupStep: String, Codable, CaseIterable, Sendable {
    case privacy
    case microphone
    case systemAudio
    case calendar
    case transcription
}

enum PermissionState: Equatable, Sendable {
    case notAsked
    case granted
    case denied
}

protocol SetupProgressStore: Sendable {
    func completedSteps() -> Set<SetupStep>
    func markCompleted(_ step: SetupStep)
    func reset()
}

@MainActor
protocol SetupPermissions: AnyObject {
    var microphone: PermissionState { get }
    var systemAudio: PermissionState { get }
    var calendar: PermissionState { get }
    func requestMicrophone() async
    func requestSystemAudio()
    func requestCalendar() async
}

@MainActor
@Observable
final class SetupFlow {
    private let store: SetupProgressStore
    private let permissions: SetupPermissions
    private let steps: [SetupStep]
    private let isTranscriptionReady: @MainActor () -> Bool

    private var acknowledged: Set<SetupStep>
    private var revision = 0

    init(
        store: SetupProgressStore,
        permissions: SetupPermissions,
        includesSystemAudio: Bool,
        isTranscriptionReady: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.permissions = permissions
        self.isTranscriptionReady = isTranscriptionReady
        steps = SetupStep.allCases.filter { includesSystemAudio || $0 != .systemAudio }
        acknowledged = store.completedSteps()
    }

    static var recordsSystemAudio: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    var step: SetupStep? {
        _ = revision
        return steps.first { !isDone($0) }
    }

    var isComplete: Bool {
        step == nil
    }

    var microphone: PermissionState {
        _ = revision
        return permissions.microphone
    }

    var systemAudio: PermissionState {
        _ = revision
        return permissions.systemAudio
    }

    var calendar: PermissionState {
        _ = revision
        return permissions.calendar
    }

    func acknowledgePrivacy() {
        acknowledged.insert(.privacy)
        store.markCompleted(.privacy)
        refresh()
    }

    func requestMicrophone() async {
        await permissions.requestMicrophone()
        refresh()
    }

    func requestSystemAudio() {
        permissions.requestSystemAudio()
        refresh()
    }

    func requestCalendar() async {
        await permissions.requestCalendar()
        refresh()
    }

    func skipCalendar() {
        acknowledged.insert(.calendar)
        store.markCompleted(.calendar)
        refresh()
    }

    func refresh() {
        revision += 1
    }

    private func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .privacy: acknowledged.contains(.privacy)
        case .microphone: permissions.microphone == .granted
        case .systemAudio: permissions.systemAudio == .granted
        case .calendar: permissions.calendar != .notAsked || acknowledged.contains(.calendar)
        case .transcription: isTranscriptionReady()
        }
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
