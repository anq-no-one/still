import Foundation

@MainActor
protocol AudioRecorder: AnyObject {
    /// A non-fatal note about this capture, such as system audio being
    /// unavailable while the microphone keeps recording.
    var captureNote: String? { get }

    func start(recordingID: UUID) async throws
    func finish() async throws
    func discard() async
}

extension AudioRecorder {
    var captureNote: String? { nil }
}

enum CaptureError: LocalizedError, Equatable {
    case systemAudioUnavailable
    case microphonePermissionDenied
    case insufficientStorage
    case inputUnavailable
    case interrupted

    var errorDescription: String? {
        switch self {
        case .systemAudioUnavailable:
            "Still could not capture this Mac's audio, so it is recording the microphone only."
        case .microphonePermissionDenied:
            "Still needs microphone access to record. Your earlier recordings are untouched."
        case .insufficientStorage:
            "This device is too low on storage to keep recording safely. Still stopped before losing audio."
        case .inputUnavailable:
            "The audio input changed and is no longer available. Everything recorded so far is saved."
        case .interrupted:
            "Another app took the microphone. Everything recorded so far is saved."
        }
    }
}

enum AudioStorage {
    /// Refuse to start a recording that cannot hold ten minutes of audio.
    static let requiredSeconds: TimeInterval = 600

    static func assertRoom(at url: URL, format: AudioFormat = .transcription) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }

        let needed = Int64(requiredSeconds) * Int64(format.bytesPerSecond)
        guard available >= needed else { throw CaptureError.insufficientStorage }
    }
}
