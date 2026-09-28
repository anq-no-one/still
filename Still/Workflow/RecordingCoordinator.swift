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
    private let notifier: RecordingNotifier?
    let audioTarget: SystemAudioTarget

    private(set) var workflow: RecordingWorkflow?
    private(set) var startFailure: String?
    private(set) var processingProgress: [UUID: Double] = [:]
    private var processingTasks: [UUID: Task<Void, Never>] = [:]

    init(
        library: Library,
        entitlements: Entitlements,
        makeSession: @escaping () -> TranscriptionSession,
        makeFinalTranscription: @escaping () -> FinalTranscription,
        makeSpeakerSeparation: @escaping () -> SpeakerSeparation = { .trackBased },
        expectedParticipants: @escaping @MainActor (Date) async -> [String] = { _ in [] },
        isReady: @escaping @MainActor () -> Bool = { true },
        audioTarget: SystemAudioTarget = SystemAudioTarget(),
        notifier: RecordingNotifier? = nil
    ) {
        self.isReady = isReady
        self.audioTarget = audioTarget
        self.library = library
        self.entitlements = entitlements
        self.makeSession = makeSession
        self.makeFinalTranscription = makeFinalTranscription
        self.makeSpeakerSeparation = makeSpeakerSeparation
        self.expectedParticipants = expectedParticipants
        self.notifier = notifier
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
        guard workflow.state == .saved, let draft = workflow.pendingFinalization else {
            if case .failed = workflow.state {
                journal?.fail(.recordingFailed, correlationID: workflow.recordingID)
            }
            return
        }
        self.workflow = nil
        process(draft, notify: true)
    }

    /// Stops tracking a recording the user removed while it was rendering, so
    /// the finished transcript does not resurrect a deleted row.
    func cancelProcessing(for id: UUID) {
        processingTasks[id]?.cancel()
        processingTasks[id] = nil
        processingProgress[id] = nil
    }

    func waitForBackgroundProcessing() async {
        for task in processingTasks.values {
            await task.value
        }
    }

    func speakerStarted(_ name: String) {
        workflow?.speakerStarted(name)
    }

    func otherMediaStarted() {
        workflow?.otherMediaStarted()
    }

    func otherMediaEnded() {
        workflow?.otherMediaEnded()
    }

    func speakerEnded(_ name: String) {
        workflow?.speakerEnded(name)
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

    func finishInterruptedProcessing() async {
        guard isReady(), workflow == nil else { return }

        for recording in library.recordingsInEveryProject where Self.awaitsProcessing(recording, tracks: library.tracks(forRecording: recording.id)) {
            if recording.isProcessing {
                await finalize(
                    RecordingFinalizer.Draft(
                        id: recording.id,
                        createdAt: recording.createdAt,
                        duration: recording.duration,
                        mixedMedia: recording.mixedMediaSpans ?? [],
                        suggestedProjectID: recording.projectID
                    ),
                    previous: recording,
                    notify: false
                )
            } else {
                let untitled = recording.title == RecordingTitle.from(transcript: "", date: recording.createdAt)
                await finalize(
                    RecordingFinalizer.Draft(
                        id: recording.id,
                        title: untitled ? nil : recording.title,
                        createdAt: recording.createdAt,
                        duration: recording.duration,
                        participants: await expectedParticipants(recording.createdAt),
                        suggestedProjectID: recording.projectID,
                        requiresTranscript: true
                    ),
                    previous: recording,
                    notify: false
                )
            }
        }
    }

    static func awaitsProcessing(_ recording: Recording, tracks: [AudioTrack]) -> Bool {
        guard !recording.isProjectConfirmed, !tracks.isEmpty else { return false }
        if recording.isProcessing { return true }
        return recording.transcript.isEmpty && recording.note == nil
    }

    private func process(_ draft: RecordingFinalizer.Draft, notify: Bool) {
        processingTasks[draft.id]?.cancel()
        processingProgress[draft.id] = 0
        let previous = library.storedRecordings.first(where: { $0.id == draft.id })
        processingTasks[draft.id] = Task {
            await finalize(draft, previous: previous, notify: notify)
            processingTasks[draft.id] = nil
        }
    }

    private func finalize(_ draft: RecordingFinalizer.Draft, previous: Recording?, notify: Bool) async {
        do {
            let finalizer = RecordingFinalizer(
                finalTranscription: makeFinalTranscription(),
                speakerSeparation: entitlements.allows(.speakerSeparation) ? makeSpeakerSeparation() : .trackBased,
                noteBuilder: GroundedNoteBuilder(),
                library: library
            )
            var draft = draft
            if draft.participants.isEmpty {
                draft.participants = await expectedParticipants(draft.createdAt)
            }
            var finished = try await finalizer.build(draft, progress: reportProgress(for: draft.id))
            try Task.checkCancellation()
            guard let stored = library.storedRecordings.first(where: { $0.id == draft.id }) else {
                processingProgress[draft.id] = nil
                return
            }
            finished.archivedAt = stored.archivedAt
            if stored.isDeleted {
                processingProgress[draft.id] = nil
                return
            }
            if let previous, stored.title != previous.title {
                finished.title = stored.title
            } else if finished.transcript.isEmpty, let previous, !previous.transcript.isEmpty {
                finished.transcript = previous.transcript
                finished.title = previous.title
            }
            if let userNote = stored.note, userNote != previous?.note {
                finished.note = mergeUserNote(userNote, into: finished.note)
            }
            try library.save(finished)
            processingProgress[draft.id] = nil
            journal?.record(.recordingSaved, correlationID: draft.id)
            if notify {
                await notifier?.requestAuthorization()
                await notifier?.notifyReady(title: finished.title)
            }
        } catch RecordingWorkflowError.emptyTranscript {
            try? library.purgeLocalCopy(ofRecording: draft.id)
            processingProgress[draft.id] = nil
        } catch is CancellationError {
            processingProgress[draft.id] = nil
        } catch {
            processingProgress[draft.id] = nil
            journal?.fail(.recordingFailed, error: error, correlationID: draft.id)
        }
    }

    /// Folds text the user wrote while the transcript was rendering back into
    /// the finished note. Generated items come from the final pass; anything
    /// the user authored survives it.
    private func mergeUserNote(_ userNote: Note, into generated: Note?) -> Note {
        guard var merged = generated else { return userNote }
        if !userNote.userText.isEmpty {
            merged.userText = userNote.userText
        }
        merged.summary = mergeUserAuthored(userNote.summary, into: merged.summary)
        merged.decisions = mergeUserAuthored(userNote.decisions, into: merged.decisions)
        merged.actions = mergeUserAuthored(userNote.actions, into: merged.actions)
        return merged
    }

    private func mergeUserAuthored(_ userItems: [NoteItem], into generated: [NoteItem]) -> [NoteItem] {
        let known = Set(generated.map(\.id))
        return generated + userItems.filter { $0.isUserAuthored && !known.contains($0.id) }
    }

    private func reportProgress(for id: UUID) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.processingProgress[id] != nil else { return }
                self.processingProgress[id] = max(self.processingProgress[id] ?? 0, fraction)
            }
        }
    }

    func toggle() async {
        if isRecording {
            await stopAndSave()
        } else {
            await start()
        }
    }
}
