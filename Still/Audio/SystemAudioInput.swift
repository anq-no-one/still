import AVFoundation
import Foundation

final class SystemAudioInput: @unchecked Sendable {
    private let format: AudioFormat
    private let consumers = ConsumerList()

    init(format: AudioFormat = .transcription) {
        self.format = format
    }

    var pcmFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        )
    }

    func attach(_ makeConsumer: (AVAudioFormat) throws -> MicrophoneInput.Consumer) throws -> UUID {
        guard let pcmFormat else { throw CaptureError.inputUnavailable }
        return consumers.insert(try makeConsumer(pcmFormat))
    }

    func detach(_ id: UUID) {
        consumers.remove(id)
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        consumers.deliver(buffer)
    }
}
