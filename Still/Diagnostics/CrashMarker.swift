import Darwin
import Foundation

struct CrashReport: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case signal
        case exception
    }

    var kind: Kind
    var signal: Int32?
    var code: Int32?
    var faultAddress: UInt?
    var name: String?
    var reason: String?
    var at: Date?
    var backtrace: Backtrace?

    var title: String {
        switch kind {
        case .signal: "\(CrashMarker.signalName(signal ?? 0)) code=\(code ?? 0) address=0x\(String(faultAddress ?? 0, radix: 16))"
        case .exception: "\(name ?? "NSException"): \(reason ?? "")"
        }
    }

    var fields: [String: String] {
        var fields = ["kind": kind.rawValue, "title": title]
        if let at { fields["crashedAt"] = at.formatted(.iso8601) }
        if let backtrace { fields["stack"] = backtrace.hex }
        return fields
    }

    /// The marker is plain text written from inside a signal handler, one
    /// crash per `crash` line followed by its `frames` line.
    static func parse(_ text: String) -> [CrashReport] {
        var reports: [CrashReport] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let head = parts.first else { continue }
            let rest = parts.count > 1 ? parts[1] : ""
            switch head {
            case "crash":
                let values = Self.values(rest)
                reports.append(CrashReport(
                    kind: .signal,
                    signal: values["signal"].flatMap { Int32($0) },
                    code: values["code"].flatMap { Int32($0) },
                    faultAddress: values["address"].flatMap { UInt($0.dropFirst(2), radix: 16) },
                    at: values["time"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                ))
            case "exception":
                let values = Self.values(rest)
                reports.append(CrashReport(
                    kind: .exception,
                    name: values["name"]?.removingPercentEncoding,
                    reason: values["reason"]?.removingPercentEncoding,
                    at: values["time"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                ))
            case "frames":
                guard !reports.isEmpty else { continue }
                reports[reports.count - 1].backtrace = Backtrace(hex: rest)
            default:
                continue
            }
        }
        return reports
    }

    private static func values(_ text: String) -> [String: String] {
        text.split(separator: " ").reduce(into: [:]) { values, pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
    }
}

private nonisolated(unsafe) var markerDescriptor: Int32 = -1
private nonisolated(unsafe) var markerBuffer: UnsafeMutablePointer<UInt8>?
private nonisolated(unsafe) var markerFrames: UnsafeMutablePointer<UInt>?
private nonisolated(unsafe) var markerMask: UInt = 0
private nonisolated(unsafe) var previousActions: UnsafeMutablePointer<sigaction>?
private let markerBufferSize = 8_192
private let crashSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

/// Leaves a note on disk when the app crashes, so the next launch can say
/// what killed the previous one and where. The system crash report and
/// MetricKit still run: the handler re-raises with the earlier action.
enum CrashMarker {
    static func markerURL(in directory: URL) -> URL {
        directory.appending(path: "crash-marker.txt")
    }

    static func imagesURL(in directory: URL) -> URL {
        directory.appending(path: "session-images.json")
    }

    static func crashesDirectory(in directory: URL) -> URL {
        directory.appending(path: "Crashes", directoryHint: .isDirectory)
    }

    /// Moves what the previous launch left into `Crashes/<stamp>/` with the
    /// binary images of that launch, and returns what it found.
    @discardableResult
    static func collectPrevious(in directory: URL) -> [CrashReport] {
        let marker = markerURL(in: directory)
        guard let text = try? String(contentsOf: marker, encoding: .utf8), !text.isEmpty else { return [] }
        let reports = CrashReport.parse(text)
        let stamp = (reports.first?.at ?? .now).formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let destination = crashesDirectory(in: directory).appending(path: stamp, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: marker, to: destination.appending(path: "crash.txt"))
        try? FileManager.default.copyItem(at: imagesURL(in: directory), to: destination.appending(path: "images.json"))
        if let data = try? JSONEncoder().encode(reports) {
            try? data.write(to: destination.appending(path: "crash.json"))
        }
        return reports
    }

    static func install(in directory: URL) {
        guard markerDescriptor < 0 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let images = try? JSONEncoder().encode(BinaryImages.snapshot()) {
            try? images.write(to: imagesURL(in: directory), options: .atomic)
        }
        let descriptor = open(markerURL(in: directory).path(percentEncoded: false), O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        markerDescriptor = descriptor
        markerBuffer = .allocate(capacity: markerBufferSize)
        markerFrames = .allocate(capacity: StackSampler.maximumFrames)
        markerMask = StackSampler.addressMask
        previousActions = .allocate(capacity: 32)
        previousActions?.initialize(repeating: sigaction(), count: 32)

        let stackSize = 64 * 1024
        var alternate = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: stackSize, alignment: 16), ss_size: stackSize, ss_flags: 0)
        sigaltstack(&alternate, nil)

        for signal in crashSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = crashSignalHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, previousActions.map { $0 + Int(signal) })
        }
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let reason = (exception.reason ?? "").prefix(500).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let frames = exception.callStackReturnAddresses.map { "0x" + String($0.uintValue, radix: 16) }.joined(separator: " ")
            let text = "exception name=\(name) reason=\(reason) time=\(Int(Date.now.timeIntervalSince1970))\nframes \(frames)\n"
            _ = text.withCString { write(markerDescriptor, $0, strlen($0)) }
        }
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: "SIGABRT"
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGILL: "SIGILL"
        case SIGTRAP: "SIGTRAP"
        case SIGFPE: "SIGFPE"
        default: "signal \(signal)"
        }
    }
}

private func crashSignalHandler(_ signal: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    if let buffer = markerBuffer, let frames = markerFrames, markerDescriptor >= 0 {
        var writer = SignalSafeWriter(buffer: buffer, capacity: markerBufferSize)
        writer.append("crash signal=")
        writer.append(decimal: Int(signal))
        writer.append(" code=")
        writer.append(decimal: Int(info?.pointee.si_code ?? 0))
        writer.append(" address=0x")
        writer.append(hex: UInt(bitPattern: info?.pointee.si_addr))
        writer.append(" time=")
        writer.append(decimal: time(nil))
        writer.append("\nframes")
        #if arch(arm64)
        if let state = context?.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext?.pointee.__ss {
            let count = StackSampler.walkFrames(pc: UInt(state.__pc), lr: UInt(state.__lr), fp: UInt(state.__fp), into: frames, mask: markerMask)
            for index in 0..<count {
                writer.append(" 0x")
                writer.append(hex: frames[index])
            }
        }
        #endif
        writer.append("\n")
        _ = write(markerDescriptor, buffer, writer.length)
    }
    if let previous = previousActions {
        sigaction(signal, previous + Int(signal), nil)
    } else {
        Darwin.signal(signal, SIG_DFL)
    }
    raise(signal)
}

private struct SignalSafeWriter {
    let buffer: UnsafeMutablePointer<UInt8>
    let capacity: Int
    var length = 0

    mutating func append(_ text: StaticString) {
        text.withUTF8Buffer { bytes in
            for byte in bytes { put(byte) }
        }
    }

    mutating func append(decimal value: Int) {
        var value = value
        if value < 0 {
            put(UInt8(ascii: "-"))
            value = -value
        }
        var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var count = 0
        withUnsafeMutableBytes(of: &digits) { raw in
            repeat {
                raw[count] = UInt8(ascii: "0") + UInt8(value % 10)
                value /= 10
                count += 1
            } while value > 0 && count < raw.count
            for index in stride(from: count - 1, through: 0, by: -1) { put(raw[index]) }
        }
    }

    mutating func append(hex value: UInt) {
        var started = false
        for shift in stride(from: UInt.bitWidth - 4, through: 0, by: -4) {
            let nibble = UInt8((value >> UInt(shift)) & 0xF)
            if nibble != 0 || started || shift == 0 {
                started = true
                put(nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + nibble - 10)
            }
        }
    }

    private mutating func put(_ byte: UInt8) {
        guard length < capacity else { return }
        buffer[length] = byte
        length += 1
    }
}
