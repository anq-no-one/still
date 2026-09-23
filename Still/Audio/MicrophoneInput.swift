import AVFoundation
import Foundation

/// The one engine that owns the microphone. The recording and the live
/// transcript attach to it and receive the same buffers, so they never compete
/// for the input or reconfigure the audio session under each other.
@MainActor
final class MicrophoneInput {
    typealias Consumer = @Sendable (AVAudioPCMBuffer) -> Void

    private let engine = AVAudioEngine()
    private let consumers = ConsumerList()
    private let fixture: AudioFixture?

    /// A fixture replaces the microphone with a recorded file played at real
    /// speed, so an end-to-end run hears the same words every time.
    init(fixture: URL? = nil) {
        self.fixture = fixture.flatMap(AudioFixture.init(url:))
    }

    var isRunning: Bool {
        fixture?.isPlaying ?? engine.isRunning
    }

    /// Hands the consumer the input's real format before the first buffer
    /// arrives, so a consumer can build its converter once.
    func attach(_ makeConsumer: (AVAudioFormat) throws -> Consumer) throws -> UUID {
        if let fixture {
            let id = consumers.insert(try makeConsumer(fixture.format))
            fixture.play(to: consumers)
            return id
        }

        let wasRunning = engine.isRunning
        if !wasRunning {
            try configureSession()
        }

        do {
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw CaptureError.inputUnavailable }

            let id = consumers.insert(try makeConsumer(format))
            if !wasRunning {
                do {
                    try start(format: format)
                } catch {
                    consumers.remove(id)
                    throw error
                }
            }
            return id
        } catch {
            if !wasRunning { deactivateSession() }
            throw error
        }
    }

    func detach(_ id: UUID) {
        guard consumers.remove(id), consumers.isEmpty else { return }
        stop()
    }

    private func start(format: AVAudioFormat) throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4_096, format: format, block: Self.tap(delivering: consumers))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.inputUnavailable
        }
    }

    private func stop() {
        if let fixture {
            fixture.stop()
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        deactivateSession()
    }

    /// Built outside the main actor because the engine calls it on its own
    /// audio thread.
    private nonisolated static func tap(delivering consumers: ConsumerList) -> AVAudioNodeTapBlock {
        { buffer, _ in consumers.deliver(buffer) }
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

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

private final class AudioFixture: @unchecked Sendable {
    private static let framesPerBuffer: AVAudioFrameCount = 1_600

    let format: AVAudioFormat
    private let samples: AVAudioPCMBuffer
    private let queue = DispatchQueue(label: "com.andrii.still.audio-fixture")
    private var timer: DispatchSourceTimer?
    private var position: AVAudioFramePosition = 0

    init?(url: URL) {
        guard let file = try? AVAudioFile(forReading: url),
              let samples = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: samples)) != nil
        else { return nil }

        format = file.processingFormat
        self.samples = samples
    }

    var isPlaying: Bool {
        queue.sync { timer != nil }
    }

    func play(to consumers: ConsumerList) {
        queue.sync {
            guard timer == nil else { return }

            position = 0
            let interval = Double(Self.framesPerBuffer) / format.sampleRate
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval)
            timer.setEventHandler { [weak self] in
                guard let self, let buffer = nextBuffer() else { return }
                consumers.deliver(buffer)
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Past the end of the file the fixture keeps delivering silence, as a
    /// quiet room does, until the recording stops.
    private func nextBuffer() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.framesPerBuffer),
              let source = samples.floatChannelData,
              let target = buffer.floatChannelData
        else { return nil }

        let frames = Int(Self.framesPerBuffer)
        let available = max(0, Int(samples.frameLength) - Int(position))
        let copied = min(frames, available)
        for channel in 0..<Int(format.channelCount) {
            let destination = target[channel]
            if copied > 0 {
                destination.update(from: source[channel] + Int(position), count: copied)
            }
            (destination + copied).update(repeating: 0, count: frames - copied)
        }
        buffer.frameLength = Self.framesPerBuffer
        position += AVAudioFramePosition(copied)
        return buffer
    }
}

private final class ConsumerList: @unchecked Sendable {
    private let lock = NSLock()
    private var consumers: [UUID: MicrophoneInput.Consumer] = [:]

    var isEmpty: Bool {
        lock.withLock { consumers.isEmpty }
    }

    func insert(_ consumer: @escaping MicrophoneInput.Consumer) -> UUID {
        let id = UUID()
        lock.withLock { consumers[id] = consumer }
        return id
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        lock.withLock { consumers.removeValue(forKey: id) != nil }
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        let current = lock.withLock { Array(consumers.values) }
        current.forEach { $0(buffer) }
    }
}
