#if os(macOS)
import Darwin
import Foundation

/// The app and its bundled `still-mcp` helper meet at a Unix domain socket in
/// their shared app group container, the one place both sandboxes can reach.
enum MCPSocketLocation {
    static let appGroup = "R3XFQ7K885.com.andrii.still"
    static let fileName = "mcp.sock"
    static let overrideKey = "STILL_MCP_SOCKET"

    static var defaultURL: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[overrideKey], !override.isEmpty {
            return URL(filePath: override)
        }
        #endif
        return containerURL.appending(path: fileName)
    }

    private static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        return realHomeDirectory.appending(path: "Library/Group Containers/\(appGroup)", directoryHint: .isDirectory)
    }

    private static var realHomeDirectory: URL {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            return URL(filePath: NSHomeDirectory())
        }
        return URL(filePath: String(cString: home), directoryHint: .isDirectory)
    }

    static func address(for url: URL) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path(percentEncoded: false).utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count <= capacity else { return nil }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func connect(to url: URL) -> Int32? {
        guard var address = address(for: url) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}
#endif
