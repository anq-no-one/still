#if os(macOS)
import Foundation

@MainActor
protocol MicrophoneTrack: AnyObject {
    var captureNote: String? { get }
    func start(recordingID: UUID) async throws
    func finish() async throws
    func discard() async
}

@MainActor
protocol SystemAudioTrack: AnyObject {
    func start(recordingID: UUID, startOffset: TimeInterval, scope: SystemAudioScope) async throws
    func finish() async throws
    func discard() async
}

extension MicrophoneRecorder: MicrophoneTrack {}
extension SystemAudioRecorder: SystemAudioTrack {}

struct MeetingTileSource: Sendable {
    let settings: MeetingTileSettingsStore
    let isVoiceActive: @Sendable () -> Bool
}

/// Runs the microphone and system-audio tracks against one recording clock.
/// Losing system audio never ends the recording; the microphone track keeps
/// journaling and the failure becomes a visible note.
@MainActor
final class MacAudioRecorder: AudioRecorder {
    private let root: URL
    private let cipher: LibraryCipher
    private let microphone: MicrophoneTrack
    private let systemAudio: SystemAudioTrack
    private let capturesSystemAudio: () -> Bool
    private let scope: @MainActor () -> SystemAudioScope
    private let tiles: MeetingTileSource?
    private let now: () -> Date

    private var isCapturingSystemAudio = false
    private var tileRecorder: MeetingTileRecorder?
    private var tileCues: [SpeakerCue] = []

    private var systemAudioNote: String?

    /// A microphone that cannot write is the worse of the two failures, because
    /// then nothing at all is being kept, so it is the one the user is told.
    var captureNote: String? {
        microphone.captureNote ?? systemAudioNote
    }

    convenience init(
        root: URL,
        cipher: LibraryCipher,
        microphoneInput: MicrophoneInput,
        systemAudioInput: SystemAudioInput,
        format: AudioFormat = .transcription,
        capturesSystemAudio: @escaping () -> Bool,
        scope: @escaping @MainActor () -> SystemAudioScope,
        tiles: MeetingTileSource? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            root: root,
            cipher: cipher,
            microphone: MicrophoneRecorder(root: root, cipher: cipher, input: microphoneInput, format: format),
            systemAudio: SystemAudioRecorder(root: root, cipher: cipher, input: systemAudioInput, format: format),
            capturesSystemAudio: capturesSystemAudio,
            scope: scope,
            tiles: tiles,
            now: now
        )
    }

    init(
        root: URL,
        cipher: LibraryCipher,
        microphone: MicrophoneTrack,
        systemAudio: SystemAudioTrack,
        capturesSystemAudio: @escaping () -> Bool,
        scope: @escaping @MainActor () -> SystemAudioScope,
        tiles: MeetingTileSource? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.root = root
        self.cipher = cipher
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.capturesSystemAudio = capturesSystemAudio
        self.scope = scope
        self.tiles = tiles
        self.now = now
    }

    func start(recordingID: UUID) async throws {
        systemAudioNote = nil
        tileCues = []
        tileRecorder = nil
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

        if isCapturingSystemAudio, let tiles, tiles.settings.isEnabled() {
            let recorder = MeetingTileRecorder(
                root: root,
                cipher: cipher,
                configuration: MeetingTileRecorder.Configuration(isVoiceActive: tiles.isVoiceActive)
            )
            await recorder.start(recordingID: recordingID)
            tileRecorder = recorder.isRunning ? recorder : nil
        }
    }

    func takeTileCues() async -> [SpeakerCue] {
        defer { tileCues = [] }
        return tileCues
    }

    func finish() async throws {
        if let tileRecorder {
            tileCues = await tileRecorder.stop()
            self.tileRecorder = nil
        }
        if isCapturingSystemAudio {
            do {
                try await systemAudio.finish()
            } catch {
                systemAudioNote = CaptureError.systemAudioUnavailable.localizedDescription
                DevLog.error("record.systemAudioFinishFailed", error)
            }
            isCapturingSystemAudio = false
        }
        try await microphone.finish()
    }

    func discard() async {
        tileRecorder?.cancel()
        tileRecorder = nil
        tileCues = []
        if isCapturingSystemAudio {
            await systemAudio.discard()
            isCapturingSystemAudio = false
        }
        await microphone.discard()
    }
}
#endif
