#if os(macOS)
import AppKit
import AVFoundation
import Foundation
import ScreenCaptureKit

@MainActor
final class SystemAudioRecorder: NSObject {
    static let launchSettleDelay: Duration = .seconds(2)

    private let root: URL
    private let cipher: LibraryCipher
    private let format: AudioFormat
    private let input: SystemAudioInput
    private let sampleQueue = DispatchQueue(label: "still.system-audio")

    private var stream: SCStream?
    private var writer: AudioChunkWriter?
    private var output: SystemAudioOutput?
    private var scope: SystemAudioScope = .callApps
    private var launchObserver: NSObjectProtocol?
    private let streamLog = SystemAudioStreamLog()
    private static var capturedApps: [String] = []

    init(root: URL, cipher: LibraryCipher, input: SystemAudioInput, format: AudioFormat = .transcription) {
        self.root = root
        self.cipher = cipher
        self.input = input
        self.format = format
    }

    func start(recordingID: UUID, startOffset: TimeInterval, scope: SystemAudioScope) async throws {
        let filter = try await Self.filter(for: scope)

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = format.sampleRate
        configuration.channelCount = format.channels
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: recordingID, track: .system, in: root),
            cipher: cipher,
            format: format,
            startOffset: startOffset
        )
        let output = SystemAudioOutput(writer: writer, input: input, startedAt: ProcessInfo.processInfo.systemUptime)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: streamLog)

        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            AudioDiagnostics.event("audio.system.started", [
                "scope": String(describing: scope),
                "sampleRate": String(configuration.sampleRate),
                "channels": String(configuration.channelCount),
                "startOffsetS": String(format: "%.3f", startOffset),
                "apps": Self.capturedApps.joined(separator: ","),
            ])
        } catch {
            AudioDiagnostics.error("audio.system.captureFailed", error, ["scope": String(describing: scope)])
            try? AudioChunkStore.discard(
                AudioChunkStore.trackDirectory(forRecording: recordingID, track: .system, in: root)
            )
            throw error
        }

        self.writer = writer
        self.output = output
        self.stream = stream
        self.scope = scope
        followLaunches()
    }

    func finish() async throws {
        stopFollowingLaunches()
        try? await stream?.stopCapture()
        output?.meter.flush(reason: "finished")
        stream = nil
        output = nil
        try writer?.finish()
        writer = nil
    }

    func discard() async {
        stopFollowingLaunches()
        try? await stream?.stopCapture()
        output?.meter.flush(reason: "discarded")
        stream = nil
        output = nil
        try? writer?.finish()
        writer = nil
    }

    private static func filter(for scope: SystemAudioScope) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.inputUnavailable }

        let apps = content.applications.filter { scope.includes($0.bundleIdentifier) }
        capturedApps = apps.map(\.bundleIdentifier)
        return SCContentFilter(display: display, including: apps, exceptingWindows: [])
    }

    private func followLaunches() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let launched = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let launched, self.scope.includes(launched) else { return }
                Task { await self.refilter() }
            }
        }
    }

    private func stopFollowingLaunches() {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        launchObserver = nil
    }

    private func refilter() async {
        try? await Task.sleep(for: Self.launchSettleDelay)
        guard let stream else { return }
        do {
            let filter = try await Self.filter(for: scope)
            try await stream.updateContentFilter(filter)
            AudioDiagnostics.event("audio.system.refiltered", ["apps": Self.capturedApps.joined(separator: ",")])
        } catch {
            AudioDiagnostics.error("audio.system.refilterFailed", error)
        }
    }
}

/// ScreenCaptureKit stops a stream on its own when the display sleeps, the
/// permission is revoked or the captured app quits; without a delegate the
/// recording would go on writing nothing from the system side.
private final class SystemAudioStreamLog: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        AudioDiagnostics.error("audio.system.streamStopped", error)
    }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput {
    private let writer: AudioChunkWriter
    private let input: SystemAudioInput
    private let startedAt: Double
    private nonisolated(unsafe) var reportedFirstBuffer = false
    let meter = AudioTapMeter(track: "system")

    init(writer: AudioChunkWriter, input: SystemAudioInput, startedAt: Double) {
        self.writer = writer
        self.input = input
        self.startedAt = startedAt
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else {
            meter.dropped()
            return
        }
        if !reportedFirstBuffer {
            reportedFirstBuffer = true
            AudioDiagnostics.event("audio.system.firstBuffer", ["afterStartMS": String(format: "%.0f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)])
        }
        guard let target = input.pcmFormat, let converted = Self.convert(sampleBuffer, to: target),
              let channel = converted.int16ChannelData
        else {
            meter.dropped()
            return
        }

        do {
            try writer.append(Data(bytes: channel[0], count: Int(converted.frameLength) * Int(target.streamDescription.pointee.mBytesPerFrame)))
        } catch {
            meter.writeFailed()
        }
        input.deliver(converted)
        let start = sampleBuffer.presentationTimeStamp
        meter.add(converted, startSeconds: start.isValid ? start.seconds : nil)
    }

    private static func convert(_ sampleBuffer: CMSampleBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let streamFormat = AVAudioFormat(streamDescription: &description)
        else { return nil }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: streamFormat,
                  bufferListNoCopy: &list,
                  deallocator: nil
              )
        else { return nil }

        guard let converter = AVAudioConverter(from: streamFormat, to: target),
           let output = AVAudioPCMBuffer(
               pcmFormat: target,
               frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / streamFormat.sampleRate) + 1_024
           )
        else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status -> AVAudioBuffer? in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
#endif
