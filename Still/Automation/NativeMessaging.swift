import Foundation

enum NativeMessageFrame {
    static let headerLength = 4
    static let maximumIncomingLength = 64 * 1024
    static let acknowledgement = encode(Data(#"{"received":true}"#.utf8))

    static func encode(_ message: Data) -> Data {
        withUnsafeBytes(of: UInt32(message.count).littleEndian) { Data($0) } + message
    }
}

struct NativeMessageReader {
    enum Failure: Error, Equatable {
        case oversized(Int)
    }

    private var buffer = Data()

    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var messages: [Data] = []

        while buffer.count >= NativeMessageFrame.headerLength {
            let length = buffer.prefix(NativeMessageFrame.headerLength)
                .reversed()
                .reduce(0) { $0 << 8 | Int($1) }
            guard length <= NativeMessageFrame.maximumIncomingLength else { throw Failure.oversized(length) }

            let end = NativeMessageFrame.headerLength + length
            guard buffer.count >= end else { break }

            messages.append(Data(buffer.dropFirst(NativeMessageFrame.headerLength).prefix(length)))
            buffer = Data(buffer.dropFirst(end))
        }

        return messages
    }
}
