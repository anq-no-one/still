import AVFoundation
import CoreVideo
import Foundation
import Testing

enum MediaFixtures {
    struct WriterStalled: Error {}

    static let sampleRate = 44_100.0
    static let framesPerSecond: Int32 = 10

    static func tone(at url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let file = try AVAudioFile(
            forWriting: url,
            settings: audioSettings(for: url.pathExtension),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData?[channel][frame] = sine(at: frame)
            }
        }
        try file.write(from: buffer)
        file.close()
    }

    static func movie(at url: URL, seconds: Int, withSound: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType(for: url.pathExtension))
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        video.expectsMediaDataInRealTime = false
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(video)

        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        sound.expectsMediaDataInRealTime = false
        if withSound { writer.add(sound) }

        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let steps = seconds * Int(framesPerSecond)
        let framesPerChunk = Int(sampleRate) / Int(framesPerSecond)
        var nextFrame = 0
        var nextChunk = withSound ? 0 : steps
        var idleRounds = 0
        while nextFrame < steps || nextChunk < steps {
            var progressed = false
            if nextFrame < steps, video.isReadyForMoreMediaData {
                let time = CMTime(value: CMTimeValue(nextFrame), timescale: framesPerSecond)
                #expect(pixels.append(try frame(from: pixels), withPresentationTime: time))
                nextFrame += 1
                if nextFrame == steps { video.markAsFinished() }
                progressed = true
            }
            if nextChunk < steps, sound.isReadyForMoreMediaData {
                #expect(sound.append(try toneSample(startingAt: nextChunk * framesPerChunk, frames: framesPerChunk)))
                nextChunk += 1
                if nextChunk == steps { sound.markAsFinished() }
                progressed = true
            }
            idleRounds = progressed ? 0 : idleRounds + 1
            guard idleRounds < 2_000 else { throw WriterStalled() }
            if !progressed { try await Task.sleep(for: .milliseconds(5)) }
        }

        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private static func frame(from adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
        return try #require(buffer)
    }

    private static func toneSample(startingAt start: Int, frames: Int) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            pcm.int16ChannelData?[0][frame] = Int16(sine(at: start + frame) * Float(Int16.max))
        }

        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        let buffer = try #require(sample)
        CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        return buffer
    }

    private static func sine(at frame: Int) -> Float {
        0.3 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
    }

    private static func fileType(for fileExtension: String) -> AVFileType {
        switch fileExtension {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
    }

    private static func audioSettings(for fileExtension: String) -> [String: Any] {
        guard fileExtension != "m4a" else {
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2]
        }

        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: fileExtension == "aiff",
        ]
    }
}
