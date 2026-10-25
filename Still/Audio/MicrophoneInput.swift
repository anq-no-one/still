import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import Foundation

@MainActor
final class MicrophoneInput {
    typealias Consumer = @Sendable (AVAudioPCMBuffer) -> Void

    private var engine = AVAudioEngine()
    private let consumers = ConsumerList()
    private let fixture: AudioFixture?
    nonisolated let meter = AudioTapMeter(track: "microphone")
    private var configurationObserver: NSObjectProtocol?

    #if os(macOS)
    var preferredDevice: @MainActor () -> String? = { nil }
    #endif

    init(fixture: URL? = nil) {
        self.fixture = fixture.flatMap(AudioFixture.init(url:))
    }

    var isRunning: Bool {
        fixture?.isPlaying ?? engine.isRunning
    }

    func attach(_ makeConsumer: (AVAudioFormat) throws -> Consumer) async throws -> UUID {
        if let fixture {
            let id = consumers.insert(try makeConsumer(fixture.format))
            fixture.play(to: consumers)
            return id
        }

        let wasRunning = engine.isRunning
        if !wasRunning {
            prepareInput()
        }

        do {
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                AudioDiagnostics.event("audio.mic.noInputFormat", deviceFields())
                throw CaptureError.inputUnavailable
            }

            let id = consumers.insert(try makeConsumer(format))
            if !wasRunning {
                do {
                    try start(format: format)
                    try await bringUpEngine()
                } catch {
                    consumers.remove(id)
                    throw error
                }
                AudioDiagnostics.event("audio.mic.started", AudioDiagnostics.formatFields(format).merging(deviceFields()) { first, _ in first })
            } else {
                AudioDiagnostics.event("audio.mic.joined", ["consumers": "shared"])
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
        input.installTap(onBus: 0, bufferSize: 4_096, format: format, block: Self.tap(delivering: consumers, meter: meter))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            AudioDiagnostics.error("audio.mic.engineStartFailed", error, AudioDiagnostics.formatFields(format).merging(deviceFields()) { first, _ in first })
            input.removeTap(onBus: 0)
            throw CaptureError.inputUnavailable
        }
        observeConfigurationChanges()
    }

    private func observeConfigurationChanges() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var fields = AudioDiagnostics.formatFields(self.engine.inputNode.outputFormat(forBus: 0))
                fields["engineRunning"] = String(self.engine.isRunning)
                fields.merge(self.deviceFields()) { first, _ in first }
                AudioDiagnostics.event("audio.mic.configurationChanged", fields)
            }
        }
    }

    private func deviceFields() -> [String: String] {
        #if os(macOS)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard let unit = engine.inputNode.audioUnit,
              AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr
        else { return ["device": "unknown"] }
        return ["device": CoreAudioInputDevices.describe(device), "preferredDevice": preferredDevice() ?? "system default"]
        #else
        return AudioRouteLog.sessionFields()
        #endif
    }

    private func stop() {
        if let fixture {
            fixture.stop()
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        meter.flush(reason: "stopped")
        AudioDiagnostics.event("audio.mic.stopped", deviceFields())
        deactivateSession()
    }

    private nonisolated static func tap(delivering consumers: ConsumerList, meter: AudioTapMeter) -> AVAudioNodeTapBlock {
        { buffer, when in
            consumers.deliver(buffer)
            meter.add(buffer, startSeconds: when.isSampleTimeValid && when.sampleRate > 0 ? Double(when.sampleTime) / when.sampleRate : nil)
        }
    }

    private func prepareInput() {
        #if os(macOS)
        engine = AVAudioEngine()
        selectPreferredDevice()
        #endif
    }

    /// Session activation can stall while the system settles the route, so it
    /// runs off the main thread. The engine itself starts synchronously in
    /// `start(format:)`, and taps stay on the main thread because they touch
    /// the consumer list.
    private func bringUpEngine() async throws {
        #if os(iOS)
        do {
            try await Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: [.allowBluetoothHFP, .defaultToSpeaker]
                )
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }.value
        } catch {
            AudioDiagnostics.error("audio.mic.sessionActivationFailed", error, AudioRouteLog.sessionFields())
            throw CaptureError.inputUnavailable
        }
        #endif
    }

    #if os(macOS)
    private func selectPreferredDevice() {
        guard let uid = preferredDevice() else { return }
        guard var device = CoreAudioInputDevices.deviceID(forUID: uid),
              let unit = engine.inputNode.audioUnit
        else {
            AudioDiagnostics.event("audio.mic.preferredDeviceMissing", ["uid": uid])
            return
        }

        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        AudioDiagnostics.event("audio.mic.deviceSelected", ["device": CoreAudioInputDevices.describe(device), "status": String(status)])
    }
    #endif

    private func deactivateSession() {
        #if os(iOS)
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
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

final class ConsumerList: @unchecked Sendable {
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
