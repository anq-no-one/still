import Foundation

@MainActor
protocol AudioRecorder: AnyObject {
    func start(recordingID: UUID) async throws
    func finish() throws
    func discard()
}

enum CaptureError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case insufficientStorage
    case inputUnavailable
    case interrupted

    var errorDescription: String? {
        switch self {
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
