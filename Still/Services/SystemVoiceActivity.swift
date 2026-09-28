import AVFoundation
import Foundation

final class SystemVoiceActivity: @unchecked Sendable {
    static let energyThreshold: Float = 0.015
    static let hangover: TimeInterval = 2

    private let lock = NSLock()
    private var lastActiveAt: Date?

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData, buffer.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
        var energy: Float = 0
        for sample in samples {
            let normalized = Float(sample) / Float(Int16.max)
            energy += normalized * normalized
        }
        ingest(rms: (energy / Float(samples.count)).squareRoot(), at: Date())
    }

    func ingest(rms: Float, at date: Date) {
        guard rms.isFinite, rms >= Self.energyThreshold else { return }
        lock.lock()
        lastActiveAt = date
        lock.unlock()
    }

    func isActive(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastActiveAt else { return false }
        return now.timeIntervalSince(lastActiveAt) <= Self.hangover
    }
}
