import Foundation

struct AudioFormat: Codable, Equatable, Sendable {
    var sampleRate: Int
    var channels: Int
    var bitsPerSample: Int

    static let transcription = AudioFormat(sampleRate: 16_000, channels: 1, bitsPerSample: 16)

    var bytesPerFrame: Int {
        channels * bitsPerSample / 8
    }

    var bytesPerSecond: Int {
        sampleRate * bytesPerFrame
    }

    func duration(ofBytes count: Int) -> TimeInterval {
        TimeInterval(count) / TimeInterval(bytesPerSecond)
    }
}

enum WAVFile {
    static func data(pcm: Data, format: AudioFormat) -> Data {
        var file = Data()
        file.append(contentsOf: Array("RIFF".utf8))
        file.append(littleEndian: UInt32(36 + pcm.count))
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        file.append(littleEndian: UInt32(16))
        file.append(littleEndian: UInt16(1))
        file.append(littleEndian: UInt16(format.channels))
        file.append(littleEndian: UInt32(format.sampleRate))
        file.append(littleEndian: UInt32(format.bytesPerSecond))
        file.append(littleEndian: UInt16(format.bytesPerFrame))
        file.append(littleEndian: UInt16(format.bitsPerSample))
        file.append(contentsOf: Array("data".utf8))
        file.append(littleEndian: UInt32(pcm.count))
        file.append(pcm)
        return file
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
