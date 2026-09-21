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
    private let now: () -> Date

    private var isCapturingSystemAudio = false

    private(set) var captureNote: String?

    init(
        root: URL,
        cipher: LibraryCipher,
        format: AudioFormat = .transcription,
        capturesSystemAudio: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        microphone = MicrophoneRecorder(root: root, cipher: cipher, format: format)
        systemAudio = SystemAudioRecorder(root: root, cipher: cipher, format: format)
        self.capturesSystemAudio = capturesSystemAudio
        self.now = now
    }

    func start(recordingID: UUID) async throws {
        captureNote = nil
        let startedAt = now()
        try await microphone.start(recordingID: recordingID)

        guard capturesSystemAudio() else { return }

        do {
            try await systemAudio.start(
                recordingID: recordingID,
                startOffset: now().timeIntervalSince(startedAt)
            )
            isCapturingSystemAudio = true
        } catch {
            captureNote = CaptureError.systemAudioUnavailable.localizedDescription
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
