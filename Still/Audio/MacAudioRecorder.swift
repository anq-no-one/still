#if os(macOS)
import Foundation

/// Runs the microphone and system-audio tracks against one recording clock.
/// Losing system audio never ends the recording; the microphone track keeps
/// journaling and the failure becomes a visible note.
@MainActor
final class MacAudioRecorder: AudioRecorder {
    private let microphone: MicrophoneRecorder
    private let systemAudio: SystemAudioRecorder
    private let capturesSystemAudio: () -> Bool
    private let scope: @MainActor () -> SystemAudioScope
    private let now: () -> Date

    private var isCapturingSystemAudio = false

    private var systemAudioNote: String?

    /// A microphone that cannot write is the worse of the two failures, because
    /// then nothing at all is being kept, so it is the one the user is told.
    var captureNote: String? {
        microphone.captureNote ?? systemAudioNote
    }

    init(
        root: URL,
        cipher: LibraryCipher,
        microphoneInput: MicrophoneInput,
        systemAudioInput: SystemAudioInput,
        format: AudioFormat = .transcription,
        capturesSystemAudio: @escaping () -> Bool,
        scope: @escaping @MainActor () -> SystemAudioScope,
        now: @escaping () -> Date = Date.init
    ) {
        microphone = MicrophoneRecorder(root: root, cipher: cipher, input: microphoneInput, format: format)
        systemAudio = SystemAudioRecorder(root: root, cipher: cipher, input: systemAudioInput, format: format)
        self.capturesSystemAudio = capturesSystemAudio
        self.scope = scope
        self.now = now
    }

    func start(recordingID: UUID) async throws {
        systemAudioNote = nil
        let startedAt = now()
        try await microphone.start(recordingID: recordingID)

        guard capturesSystemAudio() else { return }

        do {
            try await systemAudio.start(
                recordingID: recordingID,
                startOffset: now().timeIntervalSince(startedAt),
                scope: scope()
            )
            isCapturingSystemAudio = true
        } catch {
            systemAudioNote = CaptureError.systemAudioUnavailable.localizedDescription
        }
    }

    func finish() async throws {
        if isCapturingSystemAudio {
            try await systemAudio.finish()
            isCapturingSystemAudio = false
        }
        try await microphone.finish()
    }

    func discard() async {
        if isCapturingSystemAudio {
            await systemAudio.discard()
            isCapturingSystemAudio = false
        }
        await microphone.discard()
    }
}
#endif
