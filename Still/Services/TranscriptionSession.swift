import Foundation

@MainActor
protocol TranscriptionSession: AnyObject {
    var transcript: String { get }
    var isRecording: Bool { get }
    var failure: String? { get }

    func start() async throws
    func stop()
}
