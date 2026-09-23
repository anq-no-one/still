import AVFoundation
import Foundation

@MainActor
final class MicrophoneRecorder: AudioRecorder {
    private let root: URL
    private let cipher: LibraryCipher
    private let format: AudioFormat
    private let input: MicrophoneInput

    private var writer: AudioChunkWriter?
    private var consumer: UUID?
    private var directory: URL?
    private var interruptionObservers: [NSObjectProtocol] = []

    var captureNote: String? {
        writer?.failure.map { _ in CaptureError.insufficientStorage.localizedDescription }
    }

    init(root: URL, cipher: LibraryCipher, input: MicrophoneInput, format: AudioFormat = .transcription) {
        self.root = root
        self.cipher = cipher
        self.input = input
        self.format = format
    }

    func start(recordingID: UUID) async throws {
        guard await hasMicrophonePermission() else { throw CaptureError.microphonePermissionDenied }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AudioStorage.assertRoom(at: root, format: format)

        let directory = AudioChunkStore.trackDirectory(forRecording: recordingID, track: .microphone, in: root)
        let writer = try AudioChunkWriter(directory: directory, cipher: cipher, format: format)
        let format = format

        do {
            consumer = try input.attach { inputFormat in
                try PCMSink(writer: writer, from: inputFormat, to: format).consumer
            }
        } catch {
            try? writer.finish()
            try? AudioChunkStore.discard(directory)
            throw error
        }

        self.directory = AudioChunkStore.directory(forRecording: recordingID, in: root)
        self.writer = writer
        observeInterruptions()
    }

    func finish() async throws {
        stopEngine()
        try writer?.finish()
        writer = nil
        directory = nil
    }

    func discard() async {
        stopEngine()
        try? writer?.finish()
        writer = nil
        if let directory {
            try? AudioChunkStore.discard(directory)
        }
        directory = nil
    }

    private func stopEngine() {
        if let consumer {
            input.detach(consumer)
            self.consumer = nil
        }
        interruptionObservers.forEach(NotificationCenter.default.removeObserver)
        interruptionObservers.removeAll()
    }

    /// An interruption or a lost input seals what is already on disk instead of
    /// letting the engine drop audio silently.
    private func observeInterruptions() {
        #if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        interruptionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { _ in
                Task { try? await self.finish() }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { _ in
                Task { try? await self.finish() }
            },
        ]
        #endif
    }

    private func hasMicrophonePermission() async -> Bool {
        await MicrophonePermission.request()
    }
}

/// Converts the input's native buffers to the Library's format and seals them
/// on the audio thread, without touching the main actor.
private final class PCMSink: @unchecked Sendable {
    private let writer: AudioChunkWriter
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init(writer: AudioChunkWriter, from source: AVAudioFormat, to format: AudioFormat) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ), let converter = AVAudioConverter(from: source, to: target) else {
            throw CaptureError.inputUnavailable
        }

        self.writer = writer
        self.converter = converter
        self.target = target
    }

    var consumer: MicrophoneInput.Consumer {
        { [self] buffer in
            guard let pcm = convert(buffer) else { return }
            try? writer.append(pcm)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate
        ) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
