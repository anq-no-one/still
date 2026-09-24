import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum MediaImportError: LocalizedError, Equatable {
    case unsupported
    case damaged
    case silentVideo
    case inaccessible
    case tooLarge
    case insufficientSpace

    var errorDescription: String? {
        switch self {
        case .unsupported:
            String(localized: "Still imports audio such as M4A, MP3, WAV, AIFF and CAF, and video such as MOV, MP4 and M4V. This file is not one of them.")
        case .damaged:
            String(localized: "Still could not read any audio in this file. It may be damaged or incomplete.")
        case .silentVideo:
            String(localized: "This video has no sound, so there is nothing to transcribe.")
        case .inaccessible:
            String(localized: "Still could not open this file. Check that it still exists and that you can read it, then try again.")
        case .tooLarge:
            String(localized: "This file is too large to import. Still imports up to three hours at a time.")
        case .insufficientSpace:
            String(localized: "There is not enough free space on this device to import this file. Free up some space, then try again.")
        }
    }
}

struct MediaFile: Equatable, Sendable {
    static let longest: TimeInterval = 3 * 3_600
    static let readBlockBytes = 1 << 20

    let url: URL
    let title: String
    let createdAt: Date?
    let kind: ImportedFile.Kind

    var imported: ImportedFile {
        ImportedFile(name: url.lastPathComponent, kind: kind)
    }

    static func inspect(_ url: URL) throws -> MediaFile {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .fileSizeKey, .isRegularFileKey, .creationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false))
        else { throw MediaImportError.inaccessible }

        guard values.isRegularFile == true,
              let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
              let kind = ImportedFile.Kind(type)
        else { throw MediaImportError.unsupported }

        guard (values.fileSize ?? 0) <= kind.largestFileBytes else { throw MediaImportError.tooLarge }

        return MediaFile(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            createdAt: values.creationDate,
            kind: kind
        )
    }

    func contentDigest() async throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw MediaImportError.inaccessible }
        defer { try? handle.close() }

        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let block = try handle.read(upToCount: Self.readBlockBytes), !block.isEmpty else { break }
            hash.update(data: block)
        }
        return Data(hash.finalize())
    }

    func soundTrack(longest: TimeInterval = Self.longest) async throws -> SoundTrack {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let length: CMTime
        do {
            tracks = try await asset.load(.tracks)
            length = try await asset.load(.duration)
        } catch {
            throw MediaImportError.damaged
        }

        guard let audio = tracks.first(where: { $0.mediaType == .audio }) else {
            throw tracks.contains { $0.mediaType == .video } ? MediaImportError.silentVideo : MediaImportError.damaged
        }
        guard length.isNumeric, length.seconds > 0 else { throw MediaImportError.damaged }
        guard length.seconds <= longest else { throw MediaImportError.tooLarge }

        return SoundTrack(asset: asset, trackID: audio.trackID, duration: length.seconds)
    }
}

struct SoundTrack: Sendable {
    let asset: AVURLAsset
    let trackID: CMPersistentTrackID
    let duration: TimeInterval

    func decodedSize(in format: AudioFormat = .transcription) -> Int64 {
        Int64((duration * Double(format.bytesPerSecond)).rounded(.up))
    }

    func decode(
        into writer: AudioChunkWriter,
        format target: AudioFormat = .transcription,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> TimeInterval {
        guard let track = try? await asset.loadTrack(withTrackID: trackID),
              let reader = try? AVAssetReader(asset: asset)
        else { throw MediaImportError.damaged }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: target.linearPCMSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaImportError.unsupported }
        reader.add(output)
        guard reader.startReading() else { throw MediaImportError.damaged }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var decodedBytes = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pcm = try Self.bytes(of: sample)
            if !pcm.isEmpty {
                try writer.append(pcm)
                decodedBytes += pcm.count
            }
            progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
        }
        try Task.checkCancellation()

        guard reader.status == .completed, decodedBytes > 0 else { throw MediaImportError.damaged }
        try writer.finish()
        return target.duration(ofBytes: decodedBytes)
    }

    private static func bytes(of sample: CMSampleBuffer) throws -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return Data() }

        let length = CMBlockBufferGetDataLength(block)
        var pcm = Data(count: length)
        let status = pcm.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { throw MediaImportError.damaged }
        return pcm
    }
}

extension ImportedFile.Kind {
    init?(_ type: UTType) {
        if type.conforms(to: .audio) {
            self = .audio
        } else if type.conforms(to: .movie) {
            self = .video
        } else {
            return nil
        }
    }

    var largestFileBytes: Int {
        switch self {
        case .audio: 2_000_000_000
        case .video: 20_000_000_000
        }
    }
}

private extension AudioFormat {
    var linearPCMSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVLinearPCMBitDepthKey: bitsPerSample,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
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
