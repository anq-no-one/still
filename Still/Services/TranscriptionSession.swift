import Foundation

@MainActor
protocol TranscriptionSession: AnyObject {
    var transcript: String { get }
    var isRecording: Bool { get }

    func start() async throws
    func stop()
}
