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
        guard await hasMicrophonePermission() else {
            AudioDiagnostics.event("audio.mic.permissionDenied")
            throw CaptureError.microphonePermissionDenied
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try AudioStorage.assertRoom(at: root, format: format)

        let directory = AudioChunkStore.trackDirectory(forRecording: recordingID, track: .microphone, in: root)
        let writer = try AudioChunkWriter(directory: directory, cipher: cipher, format: format)
        let format = format

        do {
            consumer = try await input.attach { inputFormat in
                try PCMSink(writer: writer, from: inputFormat, to: format, meter: input.meter).consumer
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

    private func observeInterruptions() {
        #if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        interruptionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] _ in
                AudioDiagnostics.event("audio.mic.endedByInterruption")
                Task { @MainActor in try? await self?.finish() }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                AudioDiagnostics.event("audio.mic.endedByMediaServicesReset")
                Task { @MainActor in try? await self?.finish() }
            },
        ]
        #endif
    }

    private func hasMicrophonePermission() async -> Bool {
        await MicrophonePermission.request()
    }
}

private final class PCMSink: @unchecked Sendable {
    private let writer: AudioChunkWriter
    private let converter: AVAudioConverter
    private let converterLock = NSLock()
    private let target: AVAudioFormat
    private let meter: AudioTapMeter

    init(writer: AudioChunkWriter, from source: AVAudioFormat, to format: AudioFormat, meter: AudioTapMeter) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ), let converter = AVAudioConverter(from: source, to: target) else {
            AudioDiagnostics.event("audio.mic.noConverter", AudioDiagnostics.formatFields(source))
            throw CaptureError.inputUnavailable
        }

        self.writer = writer
        self.converter = converter
        self.target = target
        self.meter = meter
    }

    var consumer: MicrophoneInput.Consumer {
        { [self] buffer in
            guard let pcm = converterLock.withLock({ convert(buffer) }) else {
                meter.dropped()
                return
            }
            do {
                try writer.append(pcm)
            } catch {
                meter.writeFailed()
            }
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
