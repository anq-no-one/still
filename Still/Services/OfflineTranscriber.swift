import AVFoundation
import Foundation
import Speech

/// Transcribes captured audio after a recording stops. The samples stay in
/// memory, so no plaintext audio file is written to disk.
protocol OfflineTranscriber: Sendable {
    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment]
}

struct SpeechOfflineTranscriber: OfflineTranscriber {
    /// Generous next to the few seconds a window really takes, so it only ever
    /// catches a recognizer that has stopped answering.
    static let windowTimeoutSeconds: TimeInterval = 300

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
        request.addsPunctuation = true

        for buffer in Self.buffers(from: pcm, format: audioFormat) {
            request.append(buffer)
        }
        request.endAudio()

        let language = recognizer.locale.identifier

        return try await withCheckedThrowingContinuation { continuation in
            let once = SingleResume(continuation)
            let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    once.resume(throwing: error)
                } else if let result, result.isFinal {
                    once.resume(
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

            once.hold(recognitionTask)

            // A recognizer that neither finalizes nor fails would otherwise
            // leave saving stuck with no way out.
            Task {
                try? await Task.sleep(for: .seconds(Self.windowTimeoutSeconds))
                guard !once.hasResumed else { return }

                once.abandon(with: TranscriptionError.timedOut)
            }
        }
    }

    private static func buffers(from source: Data, format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        // A Data slice does not start at zero, and the offsets below do.
        let pcm = Data(source)
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


/// The recognizer's callback can fire more than once and from any queue, while
/// a continuation may be resumed exactly once.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var task: SFSpeechRecognitionTask?

    init(_ continuation: CheckedContinuation<[TranscriptSegment], Error>) {
        self.continuation = continuation
    }

    /// The task is held here so that giving up and cancelling it happen under
    /// the same lock, from whichever queue gets there first.
    func hold(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
    }

    func abandon(with error: Error) {
        lock.lock()
        let pending = continuation
        let running = task
        continuation = nil
        task = nil
        lock.unlock()

        running?.cancel()
        pending?.resume(throwing: error)
    }

    var hasResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation == nil
    }

    func resume(returning segments: [TranscriptSegment]) {
        take()?.resume(returning: segments)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<[TranscriptSegment], Error>? {
        lock.lock()
        defer { lock.unlock() }

        let pending = continuation
        continuation = nil
        task = nil
        return pending
    }
}
