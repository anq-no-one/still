#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class MeetingTileRecorder {
    struct Configuration: Sendable {
        var cadence: TimeInterval = 20
        var firstFrameDelay: TimeInterval = 5
        var width = 1440
        var height = 900
        var isVoiceActive: @Sendable () -> Bool = { true }
        var now: @Sendable () -> Date = Date.init
    }

    private let root: URL
    private let cipher: LibraryCipher
    private let recognizer: TileTextRecognizer
    private let configuration: Configuration

    private var recordingID: UUID?
    private var startedAt: Date?
    private var timer: Task<Void, Never>?
    private var generation = 0

    init(
        root: URL,
        cipher: LibraryCipher,
        recognizer: TileTextRecognizer = VisionTileTextRecognizer(),
        configuration: Configuration = Configuration()
    ) {
        self.root = root
        self.cipher = cipher
        self.recognizer = recognizer
        self.configuration = configuration
    }

    var isRunning: Bool {
        recordingID != nil
    }

    func start(recordingID: UUID) async {
        if isRunning {
            cancel()
        }
        let windows = (try? await TeamsMeetingWindow.fetchWindows()) ?? []
        guard TeamsMeetingWindow.resolve(from: windows) != nil else { return }
        self.recordingID = recordingID
        startedAt = configuration.now()
        timer = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() async -> [SpeakerCue] {
        let id = recordingID
        let start = startedAt
        reset()
        guard let recordingID = id, let startedAt = start else { return [] }
        let root = root
        let cipher = cipher
        let recognizer = recognizer
        let elapsed = configuration.now().timeIntervalSince(startedAt)
        defer { MeetingTileStore.discard(recordingID: recordingID, root: root) }
        return await Task.detached(priority: .utility) {
            do {
                let frames = try MeetingTileStore.frames(recordingID: recordingID, root: root, cipher: cipher)
                var observations: [TileObservation] = []
                for frame in frames {
                    observations.append(TileObservation(offset: frame.offset, names: try await recognizer.recognizeNames(in: frame.png)))
                }
                return TileCueBuilder.cues(from: observations, endingAt: elapsed)
            } catch {
                return []
            }
        }.value
    }

    func cancel() {
        let id = recordingID
        reset()
        if let id {
            MeetingTileStore.discard(recordingID: id, root: root)
        }
    }

    private func reset() {
        timer?.cancel()
        timer = nil
        recordingID = nil
        startedAt = nil
        generation += 1
    }

    private func loop() async {
        try? await Task.sleep(for: .seconds(configuration.firstFrameDelay))
        while !Task.isCancelled {
            await captureOnce()
            try? await Task.sleep(for: .seconds(configuration.cadence))
        }
    }

    private func captureOnce() async {
        guard let recordingID, let startedAt, configuration.isVoiceActive() else { return }
        let generation = generation
        do {
            let windows = try await TeamsMeetingWindow.fetchWindows()
            guard let resolution = TeamsMeetingWindow.resolve(from: windows) else { return }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let filter = TeamsMeetingWindow.filter(for: resolution, in: content),
                  let png = try await Self.captureFrame(filter: filter, width: configuration.width, height: configuration.height)
            else { return }
            guard generation == self.generation, self.recordingID == recordingID else { return }
            try MeetingTileStore.save(
                png,
                offset: configuration.now().timeIntervalSince(startedAt),
                recordingID: recordingID,
                root: root,
                cipher: cipher
            )
        } catch {}
    }

    private nonisolated static func captureFrame(filter: SCContentFilter, width: Int, height: Int) async throws -> Data? {
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.capturesAudio = false
        streamConfiguration.width = width
        streamConfiguration.height = height
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)
        let collector = FrameCollector()
        try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: Self.frameQueue)
        try await stream.startCapture()
        let image = await withTaskGroup(of: CGImage?.self, returning: CGImage?.self) { group in
            group.addTask { try? await collector.wait() }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                collector.abandon()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        try? await stream.stopCapture()
        return image.flatMap(Self.png)
    }

    private nonisolated static let frameQueue = DispatchQueue(label: "still.tile-frame")

    private nonisolated static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private final class FrameCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Error>?

    func wait() async throws -> CGImage? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func abandon() {
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: nil)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: Self.image(from: sampleBuffer))
        }
    }

    private static func image(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let pixels = sampleBuffer.imageBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: pixels)
        return CIContext().createCGImage(image, from: image.extent)
    }
}
#endif
