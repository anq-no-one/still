#if os(macOS)
import AVFoundation
import Foundation
import ScreenCaptureKit

/// Records what the Mac plays. The stream carries only an audio output, so no
/// screen frame ever reaches Still and nothing about the display is retained.
@MainActor
final class SystemAudioRecorder: NSObject {
    private let root: URL
    private let cipher: LibraryCipher
    private let format: AudioFormat
    private let sampleQueue = DispatchQueue(label: "still.system-audio")

    private var stream: SCStream?
    private var writer: AudioChunkWriter?
    private var output: SystemAudioOutput?

    init(root: URL, cipher: LibraryCipher, format: AudioFormat = .transcription) {
        self.root = root
        self.cipher = cipher
        self.format = format
    }

    func start(recordingID: UUID, startOffset: TimeInterval) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.inputUnavailable }

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
        let output = SystemAudioOutput(writer: writer, format: format)
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration,
            delegate: nil
        )

        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            // A track that never carried audio must not survive, or the final
            // pass would attribute a speaker to silence.
            try? AudioChunkStore.discard(
                AudioChunkStore.trackDirectory(forRecording: recordingID, track: .system, in: root)
            )
            throw error
        }

        self.writer = writer
        self.output = output
        self.stream = stream
    }

    func finish() async throws {
        try? await stream?.stopCapture()
        stream = nil
        output = nil
        try writer?.finish()
        writer = nil
    }

    func discard() async {
        try? await stream?.stopCapture()
        stream = nil
        output = nil
        try? writer?.finish()
        writer = nil
    }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput {
    private let writer: AudioChunkWriter
    private let format: AudioFormat

    init(writer: AudioChunkWriter, format: AudioFormat) {
        self.writer = writer
        self.format = format
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let samples = Self.int16Samples(from: sampleBuffer, as: format) else { return }

        try? writer.append(samples)
    }

    private static func int16Samples(from sampleBuffer: CMSampleBuffer, as format: AudioFormat) -> Data? {
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

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ), let converter = AVAudioConverter(from: streamFormat, to: target),
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

        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
#endif
