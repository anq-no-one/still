import AVFoundation
import Foundation

@MainActor
final class MicrophoneRecorder: AudioRecorder {
    private let root: URL
    private let cipher: LibraryCipher
    private let format: AudioFormat
    private let engine = AVAudioEngine()

    private var writer: AudioChunkWriter?
    private var directory: URL?
    private var interruptionObservers: [NSObjectProtocol] = []

    init(root: URL, cipher: LibraryCipher, format: AudioFormat = .transcription) {
        self.root = root
        self.cipher = cipher
        self.format = format
    }

    func start(recordingID: UUID) async throws {
        guard await hasMicrophonePermission() else { throw CaptureError.microphonePermissionDenied }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AudioStorage.assertRoom(at: root, format: format)
        try configureSession()

        let directory = AudioChunkStore.trackDirectory(forRecording: recordingID, track: .microphone, in: root)
        let writer = try AudioChunkWriter(directory: directory, cipher: cipher, format: format)
        self.directory = AudioChunkStore.directory(forRecording: recordingID, in: root)
        self.writer = writer

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw CaptureError.inputUnavailable }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw CaptureError.inputUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            guard let pcm = Self.convert(buffer, using: converter, to: target) else { return }
            try? writer.append(pcm)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.inputUnavailable
        }

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
        guard engine.isRunning || writer != nil else { return }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        interruptionObservers.forEach(NotificationCenter.default.removeObserver)
        interruptionObservers.removeAll()

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func configureSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw CaptureError.inputUnavailable
        }
        #endif
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

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> Data? {
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
