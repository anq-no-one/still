import Darwin
import Foundation
import Synchronization
#if os(iOS)
import os
#endif

struct MemoryBreakdown: Codable, Equatable, Sendable {
    var footprintMB: Double
    var peakFootprintMB: Double
    var internalMB: Double
    var compressedMB: Double
    var residentMB: Double
    var mallocInUseMB: Double
    var availableMB: Double?

    var fields: [String: String] {
        var fields = [
            "footprintMB": Self.text(footprintMB),
            "peakFootprintMB": Self.text(peakFootprintMB),
            "internalMB": Self.text(internalMB),
            "compressedMB": Self.text(compressedMB),
            "residentMB": Self.text(residentMB),
            "mallocInUseMB": Self.text(mallocInUseMB),
        ]
        if let availableMB { fields["availableMB"] = Self.text(availableMB) }
        return fields
    }

    private static func text(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

struct ThreadUsage: Codable, Equatable, Sendable {
    var id: UInt64
    var name: String
    var cpuPercent: Double
    var userS: Double
    var systemS: Double
    var isMain: Bool
    var isIdle: Bool

    var label: String {
        if isMain { return "main" }
        return name.isEmpty ? "tid\(id)" : name
    }
}

/// Reads the process's own memory and threads from the kernel, the same
/// numbers Xcode's gauges and Instruments show.
enum ProcessProbe {
    private static let mainPort = Mutex<thread_t>(0)
    private static let megabyte = 1_048_576.0

    /// The main thread can only name itself, so this runs once on main early
    /// in launch; samplers on other threads compare against it.
    static func registerMainThread() {
        guard Thread.isMainThread else { return }
        let port = pthread_mach_thread_np(pthread_self())
        mainPort.withLock { $0 = port }
    }

    static var mainThread: thread_t? {
        let port = mainPort.withLock { $0 }
        return port == 0 ? nil : port
    }

    static func memory() -> MemoryBreakdown {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var malloc = malloc_statistics_t()
        malloc_zone_statistics(nil, &malloc)
        let succeeded = result == KERN_SUCCESS
        var breakdown = MemoryBreakdown(
            footprintMB: succeeded ? Double(info.phys_footprint) / megabyte : 0,
            peakFootprintMB: succeeded ? Double(info.ledger_phys_footprint_peak) / megabyte : 0,
            internalMB: succeeded ? Double(info.internal) / megabyte : 0,
            compressedMB: succeeded ? Double(info.compressed) / megabyte : 0,
            residentMB: succeeded ? Double(info.resident_size) / megabyte : 0,
            mallocInUseMB: Double(malloc.size_in_use) / megabyte
        )
        #if os(iOS)
        breakdown.availableMB = Double(os_proc_available_memory()) / megabyte
        #endif
        return breakdown
    }

    static func threads() -> [ThreadUsage] {
        threads { _ in () }.map(\.usage)
    }

    /// Thread ports are only valid inside `inspect`, which is where a caller
    /// samples a stack.
    static func threads<T>(_ inspect: (thread_t) -> T) -> [(usage: ThreadUsage, extra: T)] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, list[index])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            )
        }
        let main = mainThread
        return (0..<Int(count)).compactMap { index in
            usage(of: list[index], isMain: list[index] == main).map { ($0, inspect(list[index])) }
        }
    }

    static func usage(of thread: thread_t, isMain: Bool) -> ThreadUsage? {
        var basic = thread_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else { return nil }

        var identifier = thread_identifier_info()
        var identifierCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &identifier) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(identifierCount)) {
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierCount)
            }
        }

        var extended = thread_extended_info()
        var extendedCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
        let extendedResult = withUnsafeMutablePointer(to: &extended) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
            }
        }
        let name = extendedResult == KERN_SUCCESS ? withUnsafeBytes(of: extended.pth_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        } : ""

        func seconds(_ time: time_value_t) -> Double {
            Double(time.seconds) + Double(time.microseconds) / 1_000_000
        }
        return ThreadUsage(
            id: identifier.thread_id,
            name: name,
            cpuPercent: Double(basic.cpu_usage) / Double(TH_USAGE_SCALE) * 100,
            userS: seconds(basic.user_time),
            systemS: seconds(basic.system_time),
            isMain: isMain,
            isIdle: basic.flags & TH_FLAGS_IDLE != 0
        )
    }

    static func topThreads(_ threads: [ThreadUsage], limit: Int = 6) -> String {
        threads
            .filter { $0.cpuPercent >= 0.5 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
            .map { "\($0.label):\(String(format: "%.0f", $0.cpuPercent))" }
            .joined(separator: ",")
    }
}

/// How long work waits for a free thread in Swift's cooperative pool. A pool
/// held by blocking calls (a model running synchronously, a lock) makes every
/// `await` slow even though the main thread stays responsive.
final class ExecutorLatencyProbe: Sendable {
    private let latest = Mutex<[String: Double]>([:])

    func probe() {
        let priorities: [(String, TaskPriority)] = [("userInitiated", .userInitiated), ("utility", .utility), ("background", .background)]
        for (name, priority) in priorities {
            let queuedAt = ProcessInfo.processInfo.systemUptime
            Task.detached(priority: priority) { [self] in
                let waited = (ProcessInfo.processInfo.systemUptime - queuedAt) * 1000
                self.latest.withLock { $0[name] = waited }
            }
        }
    }

    func takeLatest() -> [String: Double] {
        latest.withLock { values in
            defer { values.removeAll() }
            return values
        }
    }
}

/// Instances alive per type. A count that stays above where it was before a
/// recording, after the recording has finished, is a leak.
enum LiveObjects {
    private static let counts = Mutex([String: Int]())
    private static let changed = Mutex(false)

    static func created(_ type: Any.Type) {
        let name = String(describing: type)
        counts.withLock { $0[name, default: 0] += 1 }
        changed.withLock { $0 = true }
    }

    static func destroyed(_ type: Any.Type) {
        let name = String(describing: type)
        counts.withLock { $0[name, default: 0] -= 1 }
        changed.withLock { $0 = true }
    }

    static func snapshot() -> [String: Int] {
        counts.withLock { $0 }
    }

    static func takeIfChanged() -> [String: Int]? {
        let didChange = changed.withLock { changed in
            defer { changed = false }
            return changed
        }
        return didChange ? snapshot() : nil
    }
}

/// Extra numbers other modules add to every resource sample, such as MLX's
/// GPU memory, without Diagnostics depending on them.
enum ResourceProbes {
    private static let probes = Mutex([String: @Sendable () -> [String: String]]())

    static func register(_ name: String, _ probe: @escaping @Sendable () -> [String: String]) {
        probes.withLock { $0[name] = probe }
    }

    static func read() -> [String: String] {
        let current = probes.withLock { $0 }
        return current.values.reduce(into: [:]) { fields, probe in
            fields.merge(probe()) { first, _ in first }
        }
    }
}
