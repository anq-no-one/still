import Foundation
import Observation

/// Owns the one active recording for the whole app, so the main window, the
/// menu bar, and a global shortcut all act on the same session and show the
/// same state.
@MainActor
@Observable
final class RecordingCoordinator {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case finalizing
        case ready
        case failed(String)
    }

    private let library: Library
    private let entitlements: Entitlements
    private let makeSession: () -> TranscriptionSession
    private let makeFinalTranscription: () -> FinalTranscription
    private let isReady: @MainActor () -> Bool
    let audioTarget: SystemAudioTarget

    private(set) var workflow: RecordingWorkflow?
    private(set) var startFailure: String?

    init(
        library: Library,
        entitlements: Entitlements,
        makeSession: @escaping () -> TranscriptionSession,
        makeFinalTranscription: @escaping () -> FinalTranscription,
        isReady: @escaping @MainActor () -> Bool = { true },
        audioTarget: SystemAudioTarget = SystemAudioTarget()
    ) {
        self.isReady = isReady
        self.audioTarget = audioTarget
        self.library = library
        self.entitlements = entitlements
        self.makeSession = makeSession
        self.makeFinalTranscription = makeFinalTranscription
    }

    var phase: Phase {
        if let startFailure { return .failed(startFailure) }

        switch workflow?.state {
        case .none, .idle: return .idle
        case .preparing: return .preparing
        case .recording: return .recording
        case .finalizing: return .finalizing
        case .saved: return .ready
        case .failed(let message): return .failed(message)
        }
    }

    var isRecording: Bool {
        phase == .recording
    }

    var canStop: Bool {
        workflow?.canSave == true
    }

    var elapsed: TimeInterval {
        workflow?.elapsed ?? 0
    }

    var canStart: Bool {
        isReady() && !isRecording && phase != .preparing
    }

    func start(capturing scope: SystemAudioScope = .callApps) async {
        guard canStart else { return }

        audioTarget.scope = scope
        startFailure = nil
        do {
            let workflow = RecordingWorkflow(
                session: makeSession(),
                finalTranscription: makeFinalTranscription(),
                recorder: try library.makeRecorder(),
                library: library,
                showsLiveDraft: entitlements.allows(.liveTranscript)
            )
            self.workflow = workflow
            await workflow.start()
        } catch {
            workflow = nil
            startFailure = error.localizedDescription
        }
    }

    func stopAndSave() async {
        guard let workflow else { return }

        await workflow.save()
        if workflow.state == .saved {
            self.workflow = nil
        }
    }

    func cancel() async {
        await workflow?.cancel()
        workflow = nil
        startFailure = nil
    }

    func toggle() async {
        if isRecording {
            await stopAndSave()
        } else {
            await start()
        }
    }
}
