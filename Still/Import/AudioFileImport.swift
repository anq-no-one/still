import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum AudioImportError: LocalizedError, Equatable {
    case unsupported
    case damaged
    case inaccessible
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported:
            String(localized: "Still imports audio files such as M4A, MP3, WAV, AIFF and CAF. This file is not one of them.")
        case .damaged:
            String(localized: "Still could not read any audio in this file. It may be damaged or incomplete.")
        case .inaccessible:
            String(localized: "Still could not open this file. Check that it still exists and that you can read it, then try again.")
        case .tooLarge:
            String(localized: "This file is too long to import. Still imports up to three hours of audio at a time.")
        }
    }
}

struct AudioFileSource: Equatable, Sendable {
    static let longest: TimeInterval = 3 * 3_600
    static let largestFileBytes = 2_000_000_000
    static let readBlockBytes = 1 << 20

    let url: URL
    let title: String
    let createdAt: Date?

    static func inspect(_ url: URL) throws -> AudioFileSource {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .fileSizeKey, .isRegularFileKey, .creationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false))
        else { throw AudioImportError.inaccessible }

        guard values.isRegularFile == true,
              let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .audio)
        else { throw AudioImportError.unsupported }

        guard (values.fileSize ?? 0) <= largestFileBytes else { throw AudioImportError.tooLarge }

        return AudioFileSource(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            createdAt: values.creationDate
        )
    }

    func contentDigest() async throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw AudioImportError.inaccessible }
        defer { try? handle.close() }

        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let block = try handle.read(upToCount: Self.readBlockBytes), !block.isEmpty else { break }
            hash.update(data: block)
        }
        return Data(hash.finalize())
    }

    func decode(
        into writer: AudioChunkWriter,
        format target: AudioFormat = .transcription,
        longest: TimeInterval = Self.longest,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { throw AudioImportError.damaged }

        let source = file.processingFormat
        guard Double(file.length) / source.sampleRate <= longest else { throw AudioImportError.tooLarge }

        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(target.sampleRate),
            channels: AVAudioChannelCount(target.channels),
            interleaved: true
        ),
            let converter = AVAudioConverter(from: source, to: output)
        else { throw AudioImportError.unsupported }
        converter.downmix = true

        let inputFrames: AVAudioFrameCount = 32_768
        let outputFrames = AVAudioFrameCount(Double(inputFrames) * output.sampleRate / source.sampleRate) + 1_024
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputFrames) else {
            throw AudioImportError.damaged
        }

        var decodedBytes = 0
        var readFailed = false
        while true {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outputFrames) else {
                throw AudioImportError.damaged
            }

            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, inputStatus in
                guard !readFailed, file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: inputFrames)
                } catch {
                    readFailed = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                return input.frameLength > 0 ? input : nil
            }
            guard status != .error, !readFailed else { throw AudioImportError.damaged }

            if let samples = buffer.int16ChannelData, buffer.frameLength > 0 {
                let byteCount = Int(buffer.frameLength) * target.bytesPerFrame
                try writer.append(Data(bytes: samples[0], count: byteCount))
                decodedBytes += byteCount
            }
            progress(Double(file.framePosition) / Double(file.length))

            if status == .endOfStream { break }
        }

        guard decodedBytes > 0 else { throw AudioImportError.damaged }
        try writer.finish()
        return target.duration(ofBytes: decodedBytes)
    }
}

enum ImportIdentity {
    static func recordingID(forContentDigest digest: Data, key: SymmetricKey) -> UUID {
        var bytes = Array(HMAC<SHA256>.authenticationCode(for: digest, using: key).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
