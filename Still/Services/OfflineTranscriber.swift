import Foundation

protocol OfflineTranscriber: Sendable {
    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment]
}

struct ParakeetOfflineTranscriber: OfflineTranscriber {
    let engine: ParakeetEngine

    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment] {
        let samples = PCMSamples.floats(fromInt16: pcm, channels: format.channels)
        let words = try await engine.words(in: samples)
        return TranscriptPhrases.segments(from: words)
    }
}

enum PCMSamples {
    static func floats(fromInt16 pcm: Data, channels: Int) -> [Float] {
        let data = Data(pcm)
        let channelCount = max(1, channels)
        return data.withUnsafeBytes { raw -> [Float] in
            let values = raw.bindMemory(to: Int16.self)
            let frames = values.count / channelCount
            return (0..<frames).map { frame in
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += Float(values[frame * channelCount + channel])
                }
                return sum / Float(channelCount) / Float(Int16.max)
            }
        }
    }
}
