#if os(macOS)
import Darwin
import Foundation

enum MCPSocketServerError: LocalizedError {
    case pathTooLong
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong:
            "The connection path for AI tools is too long."
        case .system(let call, let code):
            "Still could not open the connection for AI tools (\(call): \(String(cString: strerror(code))))."
        }
    }
}

/// Listens on a Unix domain socket that only this user can open. Nothing here
/// can reach another machine: the socket family is AF_UNIX and the path lives
/// in the app group container.
final class MCPSocketServer: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.andrii.still.mcp.listener")
    private var listener: DispatchSourceRead?

    init(url: URL) {
        self.url = url
    }

    func start(onConnection: @escaping @Sendable (MCPConnection) -> Void) throws {
        guard var address = MCPSocketLocation.address(for: url) else { throw MCPSocketServerError.pathTooLong }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(url.path(percentEncoded: false))

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MCPSocketServerError.system("socket", errno) }

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw MCPSocketServerError.system("bind", code)
        }
        chmod(url.path(percentEncoded: false), 0o600)

        guard listen(descriptor, 8) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw MCPSocketServerError.system("listen", code)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            onConnection(MCPConnection(descriptor: client))
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        listener = source
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(url.path(percentEncoded: false))
    }
}

final class MCPConnection: @unchecked Sendable {
    let id = UUID()
    let lines: AsyncStream<Data>

    private let descriptor: Int32
    private let readQueue = DispatchQueue(label: "com.andrii.still.mcp.read")
    private let writeQueue = DispatchQueue(label: "com.andrii.still.mcp.write")
    private let reader: DispatchSourceRead
    private var isClosing = false
    private var isReaderDone = false
    private var isDescriptorClosed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        let (lines, continuation) = AsyncStream.makeStream(of: Data.self)
        self.lines = lines

        let buffer = LineBufferBox()
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        reader.setEventHandler { [reader] in
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else {
                reader.cancel()
                return
            }
            for line in buffer.append(Data(chunk[0..<count])) {
                continuation.yield(line)
            }
        }
        self.reader = reader
        reader.setCancelHandler { [weak self, writeQueue] in
            continuation.finish()
            writeQueue.async {
                self?.isReaderDone = true
                self?.closeDescriptorWhenFinished()
            }
        }
        reader.resume()
    }

    deinit {
        reader.cancel()
    }

    func send(_ data: Data) {
        writeQueue.async { [self] in
            guard !isClosing else { return }
            _ = MCPSocketLocation.writeAll(data, to: descriptor)
        }
    }

    /// Everything sent before this call still reaches the peer.
    func close() {
        writeQueue.async { [self] in
            guard !isClosing else { return }
            isClosing = true
            shutdown(descriptor, SHUT_RDWR)
            reader.cancel()
            closeDescriptorWhenFinished()
        }
    }

    private func closeDescriptorWhenFinished() {
        guard isClosing, isReaderDone, !isDescriptorClosed else { return }
        isDescriptorClosed = true
        Darwin.close(descriptor)
    }
}

private final class LineBufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = JSONLineBuffer()

    func append(_ data: Data) -> [Data] {
        lock.withLock { buffer.append(data) }
    }
}
#endif
