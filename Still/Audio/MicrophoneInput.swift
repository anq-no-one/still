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

    var isRunning: Bool {
        engine.isRunning
    }

    /// Hands the consumer the input's real format before the first buffer
    /// arrives, so a consumer can build its converter once.
    func attach(_ makeConsumer: (AVAudioFormat) throws -> Consumer) throws -> UUID {
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
