import AVFoundation
import Observation

/// The draft shown while recording. It re-reads the open stretch of audio every
/// couple of seconds and seals it every fifteen, so the work per update stays
/// the same however long the meeting runs. The saved transcript comes from the
/// journaled audio instead, so a rough draft never becomes the record.
@MainActor
@Observable
final class LiveTranscriber: TranscriptionSession {
    static let updateInterval: Duration = .seconds(2)
    static let sealSeconds = 15

    private let input: MicrophoneInput
    private let engine: ParakeetEngine
    private var consumer: UUID?
    private var samples: LiveSamples?
    private var loop: Task<Void, Never>?
    private var sealed = ""

    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var failure: String?

    init(input: MicrophoneInput, engine: ParakeetEngine) {
        self.input = input
        self.engine = engine
    }

    func start() async throws {
        guard !isRecording else { return }

        transcript = ""
        sealed = ""
        failure = nil

        let samples = LiveSamples()
        consumer = try input.attach { format in
            try samples.consumer(from: format)
        }
        self.samples = samples
        isRecording = true

        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.updateInterval)
                guard !Task.isCancelled else { return }
                await self?.update()
            }
        }
    }

    func stop() {
        guard isRecording else { return }

        loop?.cancel()
        loop = nil
        if let consumer {
            input.detach(consumer)
            self.consumer = nil
        }
        samples = nil
        isRecording = false
    }

    private func update() async {
        guard let samples else { return }

        let (open, isFull) = samples.openStretch(sealingAfter: Self.sealSeconds * ParakeetEngine.sampleRate)
        do {
            let words = try await engine.words(in: open)
            let text = TranscriptPhrases.plainText(of: words)
            if isFull {
                sealed = [sealed, text].filter { !$0.isEmpty }.joined(separator: " ")
                transcript = sealed
            } else {
                transcript = [sealed, text].filter { !$0.isEmpty }.joined(separator: " ")
            }
        } catch {
            failure = error.localizedDescription
            stop()
        }
    }
}

/// Collects the microphone at the recognizer's 16 kHz on the audio thread.
private final class LiveSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [Float] = []

    func consumer(from format: AVAudioFormat) throws -> MicrophoneInput.Consumer {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(ParakeetEngine.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: target) else {
            throw CaptureError.inputUnavailable
        }

        nonisolated(unsafe) let unsafeConverter = converter
        return { [self] buffer in
            guard let floats = Self.convert(buffer, with: unsafeConverter, to: target) else { return }
            lock.withLock { buffered += floats }
        }
    }

    /// The audio not yet sealed. Once it reaches the seal length it is handed
    /// over for the last time and the next stretch starts empty.
    func openStretch(sealingAfter limit: Int) -> ([Float], Bool) {
        lock.withLock {
            guard buffered.count >= limit else { return (buffered, false) }

            let stretch = Array(buffered.prefix(limit))
            buffered.removeFirst(limit)
            return (stretch, true)
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat) -> [Float]? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 1_024
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

        guard error == nil, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotInstalled
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            "Transcription is not set up yet. Still keeps recording and saves the audio, and you can download transcription in Settings."
        case .recognitionFailed:
            "Transcription could not finish on this device. Still keeps recording and saves the audio."
        }
    }
}
