import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Still

struct ProcessProbeTests {
    @Test
    func theMemoryBreakdownReadsTheProcessFootprint() {
        let memory = ProcessProbe.memory()

        #expect(memory.footprintMB > 1)
        #expect(memory.peakFootprintMB >= memory.footprintMB)
        #expect(memory.mallocInUseMB > 0)
    }

    @Test
    func theBusiestThreadsAreListedFirstAndIdleOnesLeftOut() {
        let threads = [
            ThreadUsage(id: 1, name: "", cpuPercent: 40, userS: 1, systemS: 0, isMain: true, isIdle: false),
            ThreadUsage(id: 2, name: "com.apple.audio.IOThread", cpuPercent: 75, userS: 1, systemS: 0, isMain: false, isIdle: false),
            ThreadUsage(id: 3, name: "", cpuPercent: 12, userS: 1, systemS: 0, isMain: false, isIdle: false),
            ThreadUsage(id: 4, name: "quiet", cpuPercent: 0.1, userS: 0, systemS: 0, isMain: false, isIdle: true),
        ]

        #expect(ProcessProbe.topThreads(threads) == "com.apple.audio.IOThread:75,main:40,tid3:12")
    }

    @Test
    func everyThreadOfTheProcessIsListed() {
        let threads = ProcessProbe.threads()

        #expect(threads.count >= 2)
        #expect(threads.allSatisfy { $0.id != 0 })
    }
}

struct LiveObjectsTests {
    private final class Tracked {
        init() { LiveObjects.created(Self.self) }
        deinit { LiveObjects.destroyed(Self.self) }
    }

    @Test
    func anInstanceCountsWhileAliveAndStopsWhenReleased() {
        let before = LiveObjects.snapshot()["Tracked"] ?? 0
        var tracked: Tracked? = Tracked()
        let whileAlive = LiveObjects.snapshot()["Tracked"] ?? 0

        withExtendedLifetime(tracked) {}
        tracked = nil

        #expect(whileAlive == before + 1)
        #expect(LiveObjects.snapshot()["Tracked"] == before)
    }
}

struct StackSamplerTests {
    @Test
    func anotherThreadsStackIsReadInsideTheCodeItIsRunning() throws {
        let worker = BusyThread()
        worker.start()
        defer { worker.stop() }
        let port = try #require(worker.waitForPort())

        let backtrace = try #require(StackSampler.backtrace(of: port))
        let images = BinaryImages.snapshot()
        let owners = backtrace.addresses.prefix(8).compactMap { BinaryImages.image(containing: $0, in: images)?.name }

        #expect(backtrace.addresses.count > 3)
        #expect(owners.contains { $0.contains("StillTests") })
    }

    @Test
    func loadedImagesCarryTheirUUIDAndTextRange() throws {
        let images = BinaryImages.snapshot()
        let tests = try #require(images.first { $0.name.contains("StillTests") })

        #expect(UUID(uuidString: tests.uuid) != nil)
        #expect(tests.textSize > 0)
    }

    @Test
    func theProfileRanksFramesEverySampleShares() {
        let samples = [
            Backtrace(addresses: [0x10, 0x20, 0x30]),
            Backtrace(addresses: [0x11, 0x20, 0x30]),
            Backtrace(addresses: [0x12, 0x21, 0x30]),
        ]

        let profile = StackSampler.profile(samples, limit: 2)

        #expect(profile.map(\.address) == [0x30, 0x20])
        #expect(profile.map(\.count) == [3, 2])
    }

    @Test
    func aBacktraceSurvivesTheHexItIsStoredAs() {
        let backtrace = Backtrace(addresses: [0x1_0000_4000, 0x1_8a00_0010])

        #expect(Backtrace(hex: backtrace.hex) == backtrace)
    }
}

@MainActor
struct HangStackTests {
    @Test
    func aHangRecordSaysWhatMainWasRunning() async throws {
        ProcessProbe.registerMainThread()
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test")
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))
        stream.setEnabled(true)
        let watchdog = MainThreadWatchdog(stream: stream)
        watchdog.start()
        try await Task.sleep(for: .milliseconds(200))

        spinOnMain(for: 0.6)
        try await Task.sleep(for: .milliseconds(300))
        watchdog.stop()
        await stream.flush()

        let hang = try #require(try stream.records().first { $0.kind == .hang && ($0.ms ?? 0) >= 500 })
        let stack = try #require(hang.fields?["stack"].flatMap(Backtrace.init(hex:)))
        let images = BinaryImages.snapshot()
        #expect(Int(hang.fields?["stackSamples"] ?? "0") ?? 0 >= 2)
        #expect(stack.addresses.contains { BinaryImages.image(containing: $0, in: images)?.name.contains("StillTests") == true })
    }
}

struct CrashMarkerTests {
    @Test
    func whatAPreviousLaunchLeftBecomesAReportAndMovesToCrashes() throws {
        let scratch = try Scratch()
        let marker = """
            crash signal=11 code=2 address=0x10 time=1761400000
            frames 0x100004000 0x100004100 0x18a000010
            exception name=NSInvalidArgumentException reason=unrecognized%20selector time=1761400001
            frames 0x100005000

            """
        try Data(marker.utf8).write(to: CrashMarker.markerURL(in: scratch.directory))
        try Data("[]".utf8).write(to: CrashMarker.imagesURL(in: scratch.directory))

        let reports = CrashMarker.collectPrevious(in: scratch.directory)

        #expect(reports.map(\.title) == ["SIGSEGV code=2 address=0x10", "NSInvalidArgumentException: unrecognized selector"])
        #expect(reports.first?.backtrace?.addresses == [0x1_0000_4000, 0x1_0000_4100, 0x1_8a00_0010])
        #expect(!FileManager.default.fileExists(atPath: CrashMarker.markerURL(in: scratch.directory).path(percentEncoded: false)))
        let saved = try FileManager.default.contentsOfDirectory(
            at: CrashMarker.crashesDirectory(in: scratch.directory),
            includingPropertiesForKeys: nil
        )
        let entry = try #require(saved.first)
        #expect(FileManager.default.fileExists(atPath: entry.appending(path: "images.json").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: entry.appending(path: "crash.txt").path(percentEncoded: false)))
    }

    @Test
    func aCleanPreviousLaunchLeavesNothingToReport() throws {
        let scratch = try Scratch()

        #expect(CrashMarker.collectPrevious(in: scratch.directory).isEmpty)
    }

    @Test @MainActor
    func anAppStoreBuildDeletesWhatEarlierCrashesLeft() async throws {
        let scratch = try Scratch()
        let crashes = CrashMarker.crashesDirectory(in: scratch.directory)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        try Data("crash signal=6".utf8).write(to: CrashMarker.markerURL(in: scratch.directory))
        let developer = DeveloperDiagnostics(
            directory: scratch.directory,
            key: SymmetricKey(size: .bits256),
            streams: (DevLogStream(category: "a"), DevLogStream(category: "b"))
        )

        await developer.start(startsMonitors: false) { .appStore }

        #expect(!FileManager.default.fileExists(atPath: crashes.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: CrashMarker.markerURL(in: scratch.directory).path(percentEncoded: false)))
    }
}

private func spinOnMain(for seconds: TimeInterval) {
    let until = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < until {}
}

private final class BusyThread: Sendable {
    private let port = Mutex<thread_t>(0)
    private let running = Mutex(true)

    func start() {
        let thread = Thread { [self] in spin() }
        thread.start()
    }

    func stop() {
        running.withLock { $0 = false }
    }

    func waitForPort() -> thread_t? {
        for _ in 0..<200 {
            let current = port.withLock { $0 }
            if current != 0 { return current }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    @inline(never)
    private func spin() {
        port.withLock { $0 = pthread_mach_thread_np(pthread_self()) }
        var total = 0
        while running.withLock({ $0 }) {
            total &+= 1
        }
        _ = total
    }
}
