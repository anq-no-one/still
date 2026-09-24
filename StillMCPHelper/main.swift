import Darwin
import Foundation
import Synchronization

final class Relay: Sendable {
    static let unavailableMessage = "Still is not running, or AI tool access is off. Open Still and turn on \"Allow AI tools to read meetings\" in Settings > AI Tools."

    private let socketURL: URL
    private let connection = Mutex<Int32?>(nil)
    private let output = Mutex(())
    private let readers = DispatchGroup()

    init(socketURL: URL) {
        self.socketURL = socketURL
    }

    func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            let message = Data(line.utf8) + Data([JSONLine.newline])

            if let descriptor = connectIfNeeded(), MCPSocketLocation.writeAll(message, to: descriptor) {
                continue
            }
            disconnect()
            replyUnavailable(to: message)
        }

        if let descriptor = connection.withLock({ $0 }) {
            shutdown(descriptor, SHUT_WR)
        }
        readers.wait()
        exit(0)
    }

    private func connectIfNeeded() -> Int32? {
        if let descriptor = connection.withLock({ $0 }) { return descriptor }
        guard let descriptor = MCPSocketLocation.connect(to: socketURL) else { return nil }

        connection.withLock { $0 = descriptor }
        readers.enter()
        Thread.detachNewThread { [self] in
            forward(from: descriptor)
        }
        return descriptor
    }

    private func forward(from descriptor: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            writeToOutput(Data(chunk[0..<count]))
        }
        connection.withLock { current in
            if current == descriptor { current = nil }
        }
        close(descriptor)
        readers.leave()
    }

    private func disconnect() {
        guard let descriptor = connection.withLock({ current -> Int32? in
            defer { current = nil }
            return current
        }) else { return }
        shutdown(descriptor, SHUT_RDWR)
    }

    private func replyUnavailable(to message: Data) {
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: message),
              let id = request["id"], id != .null
        else { return }

        let reply: JSONValue = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32001, "message": .string(Self.unavailableMessage)],
        ]
        if let data = try? JSONLine.encode(reply) {
            writeToOutput(data)
        }
    }

    private func writeToOutput(_ data: Data) {
        output.withLock { _ in
            _ = MCPSocketLocation.writeAll(data, to: STDOUT_FILENO)
        }
    }
}

signal(SIGPIPE, SIG_IGN)
Relay(socketURL: MCPSocketLocation.defaultURL).run()
