import AVFoundation
import Foundation
import Speech

/// Transcribes captured audio after a recording stops. The samples stay in
/// memory, so no plaintext audio file is written to disk.
protocol OfflineTranscriber: Sendable {
    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment]
}

struct SpeechOfflineTranscriber: OfflineTranscriber {
    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment] {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceRecognitionUnavailable
        }
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ) else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        for buffer in Self.buffers(from: pcm, format: audioFormat) {
            request.append(buffer)
        }
        request.endAudio()

        let language = recognizer.locale.identifier
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }

                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    continuation.resume(
                        returning: result.bestTranscription.segments.map { segment in
                            TranscriptSegment(
                                start: segment.timestamp,
                                end: segment.timestamp + segment.duration,
                                text: segment.substring,
                                language: language,
                                confidence: segment.confidence > 0 ? Double(segment.confidence) : nil
                            )
                        }
                    )
                }
            }
        }
    }

    private static func buffers(from pcm: Data, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let framesPerBuffer = Int(format.sampleRate)
        let bytesPerBuffer = framesPerBuffer * bytesPerFrame

        return stride(from: 0, to: pcm.count, by: bytesPerBuffer).compactMap { offset -> AVAudioPCMBuffer? in
            let slice = pcm[offset..<min(offset + bytesPerBuffer, pcm.count)]
            let frames = slice.count / bytesPerFrame
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.int16ChannelData
            else { return nil }

            buffer.frameLength = AVAudioFrameCount(frames)
            slice.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
                channel[0].update(from: base, count: frames * Int(format.channelCount))
            }
            return buffer
        }
    }
}
