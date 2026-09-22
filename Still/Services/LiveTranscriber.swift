import AVFoundation
import Observation
import Speech

@MainActor
@Observable
final class LiveTranscriber: TranscriptionSession {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var failure: String?

    func start() async throws {
        guard !isRecording else { return }

        let authorization = await requestSpeechAuthorization()
        guard authorization == .authorized else {
            throw TranscriptionError.speechPermissionDenied
        }

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

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

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }

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

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            inputNode.removeTap(onBus: 0)
            recognitionRequest = nil
            recognitionTask = nil
            throw error
        }
    }

    func stop() {
        guard isRecording || recognitionRequest != nil else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
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
    case timedOut

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            "Speech recognition permission is required to transcribe a meeting."
        case .recognizerUnavailable:
            "Speech recognition is not available for the current language."
        case .onDeviceRecognitionUnavailable:
            "This language cannot be transcribed on this device without an internet connection."
        case .timedOut:
            "Speech recognition stopped responding. Your recording and its audio are saved."
        }
    }
}

