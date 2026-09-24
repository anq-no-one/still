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

    let library: Library
    private let entitlements: Entitlements
    private let makeSession: () -> TranscriptionSession
    private let makeFinalTranscription: () -> FinalTranscription
    private let makeSpeakerSeparation: () -> SpeakerSeparation
    private let expectedParticipants: @MainActor (Date) async -> [String]
    private let isReady: @MainActor () -> Bool
    let audioTarget: SystemAudioTarget

    private(set) var workflow: RecordingWorkflow?
    private(set) var startFailure: String?

    init(
        library: Library,
        entitlements: Entitlements,
        makeSession: @escaping () -> TranscriptionSession,
        makeFinalTranscription: @escaping () -> FinalTranscription,
        makeSpeakerSeparation: @escaping () -> SpeakerSeparation = { .trackBased },
        expectedParticipants: @escaping @MainActor (Date) async -> [String] = { _ in [] },
        isReady: @escaping @MainActor () -> Bool = { true },
        audioTarget: SystemAudioTarget = SystemAudioTarget()
    ) {
        self.isReady = isReady
        self.audioTarget = audioTarget
        self.library = library
        self.entitlements = entitlements
        self.makeSession = makeSession
        self.makeFinalTranscription = makeFinalTranscription
        self.makeSpeakerSeparation = makeSpeakerSeparation
        self.expectedParticipants = expectedParticipants
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

    var isCapturing: Bool {
        phase == .preparing || phase == .recording
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
                speakerSeparation: entitlements.allows(.speakerSeparation) ? makeSpeakerSeparation() : .trackBased,
                expectedParticipants: expectedParticipants,
                recorder: try library.makeRecorder(),
                library: library,
                showsLiveDraft: entitlements.allows(.liveTranscript),
                suggestedProjectID: library.defaultProjectID
            )
            self.workflow = workflow
            await workflow.start()
            journal?.record(.recordingStarted, correlationID: workflow.recordingID)
        } catch {
            workflow = nil
            startFailure = error.localizedDescription
            journal?.fail(.recordingFailed, error: error)
        }
    }

    func stopAndSave() async {
        guard let workflow else { return }

        await workflow.save()
        if workflow.state == .saved {
            journal?.record(.recordingSaved, correlationID: workflow.recordingID)
            self.workflow = nil
        } else if case .failed = workflow.state {
            journal?.fail(.recordingFailed, correlationID: workflow.recordingID)
        }
    }

    func cancel() async {
        if let workflow {
            await workflow.cancel()
            journal?.record(.recordingCancelled, correlationID: workflow.recordingID)
        }
        workflow = nil
        startFailure = nil
    }

    private var journal: DiagnosticJournal? {
        library.journal
    }

    func toggle() async {
        if isRecording {
            await stopAndSave()
        } else {
            await start()
        }
    }
}
