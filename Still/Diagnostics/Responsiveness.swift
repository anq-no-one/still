import Foundation
import Synchronization
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Measures how long a person waits after they act. Every tap, click and key
/// press is timed from the hardware event to the moment the main run loop has
/// committed the resulting frame and goes idle. Named interactions also time
/// slower milestones, such as a recording actually starting.
@MainActor
enum Interactions {
    private struct Pending {
        let startedAt: Double
        let screen: String
    }

    private static var pending: [String: Pending] = [:]
    private(set) static var screen = "launch"
    private static var lastInputAt: Double?
    private static var lastInputName: String?
    private static var observingInput = false

    static func begin(_ name: String, _ fields: [String: String] = [:]) {
        let now = ProcessInfo.processInfo.systemUptime
        pending[name] = Pending(startedAt: now, screen: screen)
        var fields = fields
        fields["screen"] = screen
        DevLog.main.append(DevLog.record(.interaction, "\(name).begin", fields: fields))
        whenSettled { settledAt in
            var fields = fields
            fields["stage"] = "settled"
            DevLog.main.append(DevLog.record(.interaction, name, ms: (settledAt - now) * 1000, fields: fields))
        }
    }

    static func reached(_ name: String, _ milestone: String, _ fields: [String: String] = [:], ending: Bool = true) {
        guard let started = pending[name] else { return }
        if ending { pending[name] = nil }
        var fields = fields
        fields["stage"] = milestone
        fields["startScreen"] = started.screen
        let ms = (ProcessInfo.processInfo.systemUptime - started.startedAt) * 1000
        DevLog.main.append(DevLog.record(.interaction, name, ms: ms, fields: fields))
    }

    static func screenAppeared(_ name: String) {
        screen = name
        var fields = ["screen": name]
        var ms: Double?
        if let lastInputAt, ProcessInfo.processInfo.systemUptime - lastInputAt < 10 {
            ms = (ProcessInfo.processInfo.systemUptime - lastInputAt) * 1000
            fields["afterInput"] = lastInputName ?? "input"
        }
        DevLog.main.append(DevLog.record(.interaction, "screen.appear", ms: ms, fields: fields))
    }

    static func input(_ kind: String, eventTimestamp: TimeInterval, _ fields: [String: String] = [:]) {
        let handledAt = ProcessInfo.processInfo.systemUptime
        lastInputAt = eventTimestamp
        lastInputName = kind
        var fields = fields
        fields["screen"] = screen
        fields["queuedMS"] = String(format: "%.1f", max(0, handledAt - eventTimestamp) * 1000)
        whenSettled { settledAt in
            DevLog.main.append(DevLog.record(.interaction, "input.\(kind)", ms: (settledAt - eventTimestamp) * 1000, fields: fields))
        }
    }

    /// Runs after Core Animation's commit observer, so the time includes the
    /// SwiftUI update, layout and the frame commit the action caused.
    static func whenSettled(_ body: @escaping @MainActor (Double) -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            CFIndex.max
        ) { _, _ in
            let now = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated { body(now) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    static func observeAllInput() {
        guard !observingInput else { return }
        observingInput = true
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? UIWindow else { return }
            MainActor.assumeIsolated { PassiveTouchObserver.install(on: window) }
        }
        #else
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyDown]) { event in
            let kind: String = switch event.type {
            case .keyDown: "key"
            case .rightMouseUp: "rightClick"
            default: "click"
            }
            var fields: [String: String] = [:]
            if event.type == .keyDown {
                fields["keyCode"] = String(event.keyCode)
                fields["modifiers"] = String(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            } else {
                fields["window"] = event.window?.identifier?.rawValue ?? event.window.map { String(describing: type(of: $0)) } ?? "-"
            }
            Interactions.input(kind, eventTimestamp: event.timestamp, fields)
            return event
        }
        #endif
    }
}

#if os(iOS)
private final class PassiveTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    static func install(on window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0 is PassiveTouchObserver }) else { return }
        let observer = PassiveTouchObserver(target: nil, action: nil)
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        observer.delegate = observer
        window.addGestureRecognizer(observer)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            let point = touch.location(in: view)
            Interactions.input(
                "tap",
                eventTimestamp: touch.timestamp,
                ["x": String(Int(point.x)), "y": String(Int(point.y))]
            )
        }
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif

/// Notices when the main thread stops answering. A ping that waits longer
/// than the threshold is a hang; the spans running on main at that moment say
/// what was blocking it.
final class MainThreadWatchdog: Sendable {
    static let threshold: TimeInterval = 0.1
    static let firstSample: TimeInterval = 0.25
    static let sampleInterval: TimeInterval = 0.1
    static let maximumSamples = 50
    static let longHang: TimeInterval = 2
    private let running = Mutex(false)
    private let appActive = Mutex(true)
    private let stream: DevLogStream
    private let onLongHang: (@Sendable () -> Void)?

    init(stream: DevLogStream = DevLog.main, onLongHang: (@Sendable () -> Void)? = nil) {
        self.stream = stream
        self.onLongHang = onLongHang
    }

    func start() {
        let alreadyRunning = running.withLock { running in
            defer { running = true }
            return running
        }
        guard !alreadyRunning else { return }
        let thread = Thread { [self] in loop() }
        thread.name = "still.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        running.withLock { $0 = false }
    }

    func setAppActive(_ active: Bool) {
        appActive.withLock { $0 = active }
    }

    private func loop() {
        while running.withLock({ $0 }) {
            let sent = ProcessInfo.processInfo.systemUptime
            let wasActive = appActive.withLock { $0 }
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            var blockedBy: [String] = []
            var samples: [Backtrace] = []
            if answered.wait(timeout: .now() + Self.threshold) == .timedOut {
                blockedBy = Perf.mainActivity
                samples = sampleMain(until: answered, sentAt: sent)
            }
            let waited = ProcessInfo.processInfo.systemUptime - sent
            if waited >= Self.threshold, wasActive, appActive.withLock({ $0 }), waited < 60 {
                var fields = ["severity": waited >= 0.5 ? "hang" : waited >= 0.25 ? "stall" : "microHang"]
                if !blockedBy.isEmpty { fields["blockedBy"] = blockedBy.joined(separator: " > ") }
                fields.merge(Self.stackFields(samples)) { first, _ in first }
                stream.append(DevLog.record(.hang, "main.unresponsive", ms: waited * 1000, thread: "main", fields: fields))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// From a quarter second into the wait, main's stack is read every
    /// 100 ms until it answers, so the record says what it was doing.
    private func sampleMain(until answered: DispatchSemaphore, sentAt sent: Double) -> [Backtrace] {
        let firstSampleAt = sent + Self.firstSample
        if answered.wait(timeout: .now() + max(0, firstSampleAt - ProcessInfo.processInfo.systemUptime)) == .success {
            return []
        }
        var samples: [Backtrace] = []
        var tookSnapshot = false
        repeat {
            if let sample = StackSampler.backtraceOfMain() { samples.append(sample) }
            if !tookSnapshot, ProcessInfo.processInfo.systemUptime - sent >= Self.longHang {
                tookSnapshot = true
                onLongHang?()
            }
        } while samples.count < Self.maximumSamples && answered.wait(timeout: .now() + Self.sampleInterval) == .timedOut
        if samples.count >= Self.maximumSamples {
            answered.wait()
        }
        return samples
    }

    static func stackFields(_ samples: [Backtrace]) -> [String: String] {
        guard let heaviest = StackSampler.heaviest(samples) else { return [:] }
        let images = BinaryImages.snapshot()
        return [
            "stack": heaviest.hex,
            "stackSamples": String(samples.count),
            "stackProfile": StackSampler.profile(samples, limit: 12).map { "\($0.count)x0x\(String($0.address, radix: 16))" }.joined(separator: " "),
            "stackSymbols": heaviest.symbolicated(with: images).prefix(16)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " | "),
        ]
    }
}

/// Every few seconds: process CPU and the busiest threads, a memory
/// breakdown, how long the cooperative pool keeps work waiting, thermal
/// state, live objects, and how often each instrumented view re-rendered.
final class ResourceSampler: Sendable {
    private let timer = Mutex<DispatchSourceTimer?>(nil)
    private let previous = Mutex<(cpu: Double, at: Double)?>(nil)
    private let executor = ExecutorLatencyProbe()

    func start(every interval: TimeInterval = 5) {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        source.setEventHandler { [self] in sample() }
        timer.withLock { $0?.cancel(); $0 = source }
        source.resume()
        sample()
    }

    private func sample() {
        let span = Perf.begin("diag.sample", measuresCPU: true)
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = Self.processCPUSeconds()
        let last = previous.withLock { previous in
            defer { previous = (cpu, now) }
            return previous
        }
        let threads = ProcessProbe.threads()
        var fields = ProcessProbe.memory().fields
        fields["threads"] = String(threads.count)
        fields["topThreads"] = ProcessProbe.topThreads(threads)
        fields["thermal"] = Self.thermalName(ProcessInfo.processInfo.thermalState)
        fields["lowPower"] = String(ProcessInfo.processInfo.isLowPowerModeEnabled)
        if let last, now > last.at {
            fields["cpuPercent"] = String(format: "%.0f", (cpu - last.cpu) / (now - last.at) * 100)
        }
        for (priority, ms) in executor.takeLatest() {
            fields["executorMS.\(priority)"] = String(format: "%.1f", ms)
        }
        fields.merge(ResourceProbes.read()) { first, _ in first }
        DevLog.main.append(DevLog.record(.sample, "resources", thread: nil, fields: fields))
        executor.probe()

        let counters = Perf.takeCounters()
        if !counters.isEmpty {
            DevLog.main.append(
                DevLog.record(.counter, "renders", thread: nil, fields: counters.mapValues(String.init))
            )
        }
        if let objects = LiveObjects.takeIfChanged() {
            DevLog.main.append(
                DevLog.record(.counter, "liveObjects", thread: nil, fields: objects.mapValues(String.init))
            )
        }
        Perf.end(span)
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

extension View {
    /// Names the screen in the developer log and times how long it took to
    /// appear after the input that opened it.
    func perfScreen(_ name: String) -> some View {
        onAppear { Interactions.screenAppeared(name) }
    }
}
