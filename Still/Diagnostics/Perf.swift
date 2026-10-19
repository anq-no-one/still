import Foundation
import os
import Synchronization

struct PerfStat: Codable, Equatable, Sendable {
    var count = 0
    var onMain = 0
    var totalMS = 0.0
    var maxMS = 0.0
    var samples: [Double] = []

    static let sampleLimit = 4096

    mutating func add(_ ms: Double, onMain main: Bool) {
        count += 1
        if main { onMain += 1 }
        totalMS += ms
        maxMS = max(maxMS, ms)
        if samples.count < Self.sampleLimit {
            samples.append(ms)
        } else {
            samples[count % Self.sampleLimit] = ms
        }
    }

    func percentile(_ fraction: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}

struct PerfSpan: Sendable {
    let name: String
    let startedAt: Double
    let thread: String
    let cpuStart: UInt64?
    fileprivate let signpost: OSSignpostIntervalState

    var elapsedMS: Double {
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
    }
}

/// Spans go to the developer log, to a running summary, and to Instruments as
/// signposts. A synchronous span also reports the CPU time its thread spent,
/// which tells waiting apart from working.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.andrii.still", category: .pointsOfInterest)

    private static let stats = Mutex([String: PerfStat]())
    private static let counters = Mutex([String: Int]())
    private static let activeOnMain = Mutex([String]())

    static func begin(_ name: String, measuresCPU: Bool = false) -> PerfSpan {
        let thread = DevLogThread.current
        if thread == "main" {
            activeOnMain.withLock { $0.append(name) }
        }
        return PerfSpan(
            name: name,
            startedAt: ProcessInfo.processInfo.systemUptime,
            thread: thread,
            cpuStart: measuresCPU ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : nil,
            signpost: signposter.beginInterval("span", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
        )
    }

    @discardableResult
    static func end(_ span: PerfSpan, _ fields: [String: String] = [:]) -> Double {
        let ms = span.elapsedMS
        signposter.endInterval("span", span.signpost)
        if span.thread == "main" {
            activeOnMain.withLock { active in
                if let index = active.lastIndex(of: span.name) { active.remove(at: index) }
            }
        }
        var fields = fields
        let endThread = DevLogThread.current
        if endThread != span.thread {
            fields["endThread"] = endThread
        }
        if let cpuStart = span.cpuStart {
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpuStart) / 1_000_000
            fields["cpuMS"] = String(format: "%.1f", cpu)
        }
        stats.withLock { $0[span.name, default: PerfStat()].add(ms, onMain: span.thread == "main") }
        DevLog.main.append(DevLog.record(.span, span.name, ms: ms, thread: span.thread, fields: fields))
        return ms
    }

    static func measure<T>(_ name: String, _ fields: [String: String] = [:], _ body: () throws -> T) rethrows -> T {
        let span = begin(name, measuresCPU: true)
        do {
            let result = try body()
            end(span, fields)
            return result
        } catch {
            var fields = fields
            fields["error"] = String(describing: error)
            end(span, fields)
            throw error
        }
    }

    static func trace<T>(
        _ name: String,
        _ fields: [String: String] = [:],
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let span = begin(name)
        do {
            let result = try await body()
            end(span, fields)
            return result
        } catch {
            var fields = fields
            fields["error"] = String(describing: error)
            end(span, fields)
            throw error
        }
    }

    static func count(_ name: String) {
        counters.withLock { $0[name, default: 0] += 1 }
    }

    static func takeCounters() -> [String: Int] {
        counters.withLock { counters in
            defer { counters.removeAll(keepingCapacity: true) }
            return counters
        }
    }

    static var mainActivity: [String] {
        activeOnMain.withLock { $0 }
    }

    static func snapshot() -> [String: PerfStat] {
        stats.withLock { $0 }
    }

    static func summary(_ stats: [String: PerfStat]) -> String {
        let header = "span".padding(toLength: 44, withPad: " ", startingAt: 0)
            + " count  onMain    p50ms    p90ms    p99ms    maxms   totalms"
        let rows = stats.sorted { $0.value.totalMS > $1.value.totalMS }.map { name, stat in
            name.padding(toLength: 44, withPad: " ", startingAt: 0)
                + String(
                    format: " %5d  %6d %8.1f %8.1f %8.1f %8.1f %9.0f",
                    stat.count, stat.onMain, stat.percentile(0.5), stat.percentile(0.9),
                    stat.percentile(0.99), stat.maxMS, stat.totalMS
                )
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}
