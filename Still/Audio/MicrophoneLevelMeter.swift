#if os(macOS)
import AVFoundation
import Foundation

@MainActor
protocol MicrophoneLevelMeter: AnyObject {
    func start(onLevel: @escaping @MainActor @Sendable (Double) -> Void) async throws
    func stop()
}

@MainActor
final class InputLevelMeter: MicrophoneLevelMeter {
    private let input: MicrophoneInput
    private var consumer: UUID?

    init(input: MicrophoneInput) {
        self.input = input
    }

    func start(onLevel: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        guard consumer == nil else { return }

        consumer = try await input.attach { _ in
            { buffer in
                guard let level = InputLevel.of(buffer) else { return }
                Task { @MainActor in onLevel(level) }
            }
        }
    }

    func stop() {
        guard let consumer else { return }
        input.detach(consumer)
        self.consumer = nil
    }
}

enum InputLevel {
    static let floor = -60.0

    static func of(_ buffer: AVAudioPCMBuffer) -> Double? {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }

        let count = Int(buffer.frameLength)
        let energy = (0..<count).reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
        let rms = Double((energy / Float(count)).squareRoot())
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floor) / -floor))
    }
}
#endif
