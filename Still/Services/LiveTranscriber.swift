import AVFoundation
import Observation
import Speech

@MainActor
@Observable
final class LiveTranscriber: TranscriptionSession {
    private let input: MicrophoneInput
    private var consumer: UUID?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var failure: String?

    init(input: MicrophoneInput) {
        self.input = input
    }

    func start() async throws {
        guard !isRecording else { return }

        let authorization = await Self.requestSpeechAuthorization()
        guard authorization == .authorized else {
            throw TranscriptionError.speechPermissionDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        recognitionRequest = request
        transcript = ""
        failure = nil

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                }

                if let error {
                    self?.failure = error.localizedDescription
                }

                if error != nil || result?.isFinal == true {
                    self?.stop()
                }
            }
        }

        nonisolated(unsafe) let audio = request
        do {
            consumer = try input.attach { _ in
                { buffer in audio.append(buffer) }
            }
            isRecording = true
        } catch {
            recognitionTask?.cancel()
            recognitionRequest = nil
            recognitionTask = nil
            throw error
        }
    }

    func stop() {
        guard isRecording || recognitionRequest != nil else { return }

        if let consumer {
            input.detach(consumer)
            self.consumer = nil
        }
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    /// The system answers on its own queue, so the callback must not belong to
    /// the main actor.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

enum TranscriptionError: LocalizedError {
    case speechPermissionDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case recognitionFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            "Speech recognition permission is required to transcribe a meeting."
        case .recognizerUnavailable:
            "Speech recognition is not available for the current language."
        case .onDeviceRecognitionUnavailable:
            "This language cannot be transcribed on this device without an internet connection."
        case .recognitionFailed:
            "Speech recognition could not finish on this device. Your recording and its audio are saved."
        case .timedOut:
            "Speech recognition stopped responding. Your recording and its audio are saved."
        }
    }
}

