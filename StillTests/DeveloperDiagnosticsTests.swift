import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

struct DevLogStreamTests {
    @Test
    func recordsWaitForTheChannelThenReachTheLog() async throws {
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test")
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))

        stream.append(DevLog.record(.event, "before.channel"))
        await stream.flush()
        #expect(try stream.records().isEmpty)

        stream.setEnabled(true)
        await stream.flush()

        #expect(try stream.records().map(\.name) == ["before.channel"])
    }

    @Test
    func anAppStoreBuildKeepsNothingAndRemovesAnEarlierLog() async throws {
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test")
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))
        stream.setEnabled(true)
        stream.append(DevLog.record(.event, "from.testflight"))
        await stream.flush()
        #expect(stream.storedBytes > 0)

        stream.setEnabled(false)
        stream.append(DevLog.record(.event, "from.appstore"))
        await stream.flush()

        #expect(stream.storedBytes == 0)
        #expect(try stream.records().isEmpty)
    }

    @Test
    func linesAreSealedOnDisk() async throws {
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test")
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))
        stream.setEnabled(true)
        stream.append(DevLog.record(.ai, "mlx.generate", fields: ["output": "Anna ships the budget"]))
        await stream.flush()

        let raw = try Data(contentsOf: scratch.directory.appending(path: "log.jsonl"))

        #expect(!raw.isEmpty)
        #expect(String(decoding: raw, as: UTF8.self).contains("Anna") == false)
    }

    @Test
    func aFullFileRollsOverAndKeepsTheNewestRecords() async throws {
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test", maximumFileBytes: 2_000)
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))
        stream.setEnabled(true)
        for index in 0..<200 {
            stream.append(DevLog.record(.event, "event.\(index)"))
            await stream.flush()
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: scratch.directory.path(percentEncoded: false))
        let names = try stream.records().map(\.name)

        #expect(files.count <= 2)
        #expect(names.last == "event.199")
        #expect(!names.contains("event.0"))
        #expect(stream.storedBytes < 6_000)
    }

    @Test
    func anExportIsReadableJSONLines() async throws {
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test")
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))
        stream.setEnabled(true)
        stream.append(DevLog.record(.span, "finalize.total", ms: 12.5, fields: ["recordingID": "A"]))
        stream.append(DevLog.record(.span, "finalize.total", ms: 3, fields: ["recordingID": "B"]))
        await stream.flush()
        let destination = scratch.directory.appending(path: "export.jsonl")

        let count = try stream.export(to: destination) { $0.fields?["recordingID"] == "A" }
        let text = try String(contentsOf: destination, encoding: .utf8)

        #expect(count == 1)
        #expect(text.contains("\"ms\":12.5"))
        #expect(!text.contains("\"recordingID\":\"B\""))
    }
}

struct PerfTests {
    @Test
    func percentilesComeFromTheRecordedSamples() {
        var stat = PerfStat()
        for ms in 1...100 {
            stat.add(Double(ms), onMain: ms.isMultiple(of: 2))
        }

        #expect(stat.count == 100)
        #expect(stat.onMain == 50)
        #expect(stat.percentile(0.5) == 50)
        #expect(stat.percentile(0.9) == 90)
        #expect(stat.maxMS == 100)
    }

    @Test @MainActor
    func aSpanSaysWhichThreadItRanOn() async {
        let onMain = "test.main.\(UUID().uuidString)"
        let offMain = "test.background.\(UUID().uuidString)"

        Perf.measure(onMain) { _ = (0..<10_000).reduce(0, +) }
        await Task.detached { Perf.measure(offMain) { _ = (0..<10_000).reduce(0, +) } }.value

        let stats = Perf.snapshot()
        #expect(stats[onMain]?.onMain == 1)
        #expect(stats[offMain]?.count == 1)
        #expect(stats[offMain]?.onMain == 0)
    }

    @Test
    func aSpanKeepsTheErrorItEndedWith() {
        let name = "test.failing.\(UUID().uuidString)"
        struct Broken: Error {}

        #expect(throws: Broken.self) {
            try Perf.measure(name) { throw Broken() }
        }
        #expect(Perf.snapshot()[name]?.count == 1)
    }
}

@MainActor
struct ResponsivenessTests {
    @Test
    func settlingWaitsForTheRunLoopToGoIdle() async throws {
        var settledAt: Double?
        let began = ProcessInfo.processInfo.systemUptime

        Interactions.whenSettled { settledAt = $0 }
        #expect(settledAt == nil)
        for _ in 0..<40 where settledAt == nil {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect((settledAt ?? 0) >= began)
    }

    @Test
    func aBlockedMainThreadIsReportedAsAHang() async throws {
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test")
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))
        stream.setEnabled(true)
        let watchdog = MainThreadWatchdog(stream: stream)
        watchdog.start()
        try await Task.sleep(for: .milliseconds(200))

        blockMainThread(for: 0.6)
        var hangs: [DevLogRecord] = []
        for _ in 0..<40 where !hangs.contains(where: { ($0.ms ?? 0) >= 300 }) {
            try await Task.sleep(for: .milliseconds(50))
            await stream.flush()
            hangs = try stream.records().filter { $0.kind == .hang }
        }
        watchdog.stop()

        #expect(hangs.contains { ($0.ms ?? 0) >= 300 })
    }
}

private func blockMainThread(for seconds: TimeInterval) {
    let until = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < until {}
}

@MainActor
struct DebugBundleTests {
    @Test
    func anAppStoreBuildOffersNoBundle() async throws {
        let scratch = try Scratch()
        let developer = DeveloperDiagnostics(streams: (DevLogStream(category: "a"), DevLogStream(category: "b")))
        let diagnostics = Diagnostics(settings: MemoryDiagnosticsSettings(), sink: SpyDiagnosticsSink(), developer: developer)
        let library = try await makeLibrary(source: FakeDeviceKeySource(), audioRoot: scratch.directory)

        await developer.start(startsMonitors: false) { .appStore }

        #expect(diagnostics.debugBundleBuilder(library: library) == nil)
    }

    @Test
    func aTestFlightBuildOffersTheBundle() async throws {
        let scratch = try Scratch()
        let developer = DeveloperDiagnostics(streams: (DevLogStream(category: "a"), DevLogStream(category: "b")))
        let diagnostics = Diagnostics(settings: MemoryDiagnosticsSettings(), sink: SpyDiagnosticsSink(), developer: developer)
        let library = try await makeLibrary(source: FakeDeviceKeySource(), audioRoot: scratch.directory)

        await developer.start(startsMonitors: false) { .testFlight }

        #expect(diagnostics.debugBundleBuilder(library: library) != nil)
    }

    @Test
    func aChannelStoreKitCouldNotNameAtLaunchIsAskedAgainWithoutLosingTheLog() async throws {
        let scratch = try Scratch()
        let (log, ai) = (DevLogStream(category: "a"), DevLogStream(category: "b"))
        let key = SymmetricKey(size: .bits256)
        log.configure(directory: scratch.directory, name: "devlog", key: key)
        ai.configure(directory: scratch.directory, name: "ai-trace", key: key)
        let developer = DeveloperDiagnostics(streams: (log, ai))
        let diagnostics = Diagnostics(settings: MemoryDiagnosticsSettings(), sink: SpyDiagnosticsSink(), developer: developer)
        let library = try await makeLibrary(source: FakeDeviceKeySource(), audioRoot: scratch.directory)
        let answers = Answers([.unknown, .testFlight])

        await developer.start(startsMonitors: false) { await answers.next() }
        log.append(DevLog.record(.event, "while.unknown"))
        await log.flush()
        #expect(diagnostics.debugBundleBuilder(library: library) == nil)

        await developer.resolveAgainIfUnknown()
        await log.flush()

        #expect(diagnostics.debugBundleBuilder(library: library) != nil)
        #expect(try log.records().map(\.name).contains("while.unknown"))
    }

    @Test
    func aBundleCarriesTheOriginalTracksTranscriptAndModelAnswers() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let audioRoot = scratch.directory.appending(path: "audio")
        let library = try await makeLibrary(source: source, audioRoot: audioRoot)
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let segments = words("We ship the budget on Friday .")
        let recording = Recording(title: "Budget review", transcript: segments.plainText, segments: segments, duration: 2)
        let other = Recording(title: "Other", transcript: "other", duration: 1)
        let format = AudioFormat.transcription
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: recording.id, track: .microphone, in: audioRoot),
            cipher: LibraryCipher(key: key),
            format: format
        )
        try writer.append(Data(repeating: 7, count: format.bytesPerSecond))
        try writer.finish()
        try library.add(recording)
        try library.add(other)

        let (log, ai) = try streams(in: scratch.directory.appending(path: "logs"))
        log.append(DevLog.record(.span, "finalize.total", ms: 1500, thread: "main", fields: ["recordingID": recording.id.uuidString]))
        ai.append(DevLog.record(.ai, "mlx.generate", fields: ["recordingID": recording.id.uuidString, "output": "{\"title\":\"Budget\"}"]))
        ai.append(DevLog.record(.ai, "mlx.generate", fields: ["recordingID": other.id.uuidString, "output": "unrelated answer"]))

        let state = DebugStateRegistry()
        state.register("sync") { ["lastFailure": "zoneNotFound"] }
        let builder = DebugBundleBuilder(
            library: library,
            journal: DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), key: SymmetricKey(size: .bits256)),
            developer: DeveloperDiagnostics(),
            context: { ["meetingMemoryPack": "qwen"] },
            state: state,
            log: log,
            aiLog: ai,
            parent: scratch.directory.appending(path: "bundles")
        )
        let folder = try await builder.prepareFolder(
            DebugBundleRequest(recordingIDs: [recording.id], includesAudio: true),
            progress: { _ in }
        )

        let recordings = try FileManager.default.contentsOfDirectory(
            at: folder.appending(path: "recordings"),
            includingPropertiesForKeys: nil
        )
        #expect(recordings.count == 1)
        let entry = try #require(recordings.first)
        let wav = try Data(contentsOf: entry.appending(path: "audio-microphone.wav"))
        let transcript = try String(contentsOf: entry.appending(path: "transcript.txt"), encoding: .utf8)
        let trace = try String(contentsOf: entry.appending(path: "ai-trace.jsonl"), encoding: .utf8)
        let device = try String(contentsOf: folder.appending(path: "device.json"), encoding: .utf8)
        let performance = try String(contentsOf: folder.appending(path: "performance.txt"), encoding: .utf8)

        #expect(wav.count == 44 + format.bytesPerSecond)
        #expect(transcript.contains("budget"))
        #expect(trace.contains("Budget"))
        #expect(!trace.contains("unrelated answer"))
        #expect(device.contains("qwen"))
        #expect(performance.contains("finalize.total"))
        #expect(FileManager.default.fileExists(atPath: entry.appending(path: "recording.json").path(percentEncoded: false)))
        let threads = try String(contentsOf: folder.appending(path: "threads.txt"), encoding: .utf8)
        let images = try JSONDecoder().decode([BinaryImage].self, from: Data(contentsOf: folder.appending(path: "images.json")))
        let memory = try String(contentsOf: folder.appending(path: "memory.json"), encoding: .utf8)
        #expect(threads.contains("Thread main"))
        #expect(images.contains { $0.name.contains("StillTests") })
        #expect(memory.contains("footprintMB"))
        let appState = try String(contentsOf: folder.appending(path: "state.json"), encoding: .utf8)
        #expect(appState.contains("zoneNotFound"))
    }

    @Test
    func aBundleWithoutAudioLeavesTheTracksOut() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let audioRoot = scratch.directory.appending(path: "audio")
        let library = try await makeLibrary(source: source, audioRoot: audioRoot)
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let recording = Recording(title: "Quiet", transcript: "words", duration: 1)
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: recording.id, track: .microphone, in: audioRoot),
            cipher: LibraryCipher(key: key)
        )
        try writer.append(Data(repeating: 1, count: 3_200))
        try writer.finish()
        try library.add(recording)
        let (log, ai) = try streams(in: scratch.directory.appending(path: "logs"))
        let builder = DebugBundleBuilder(
            library: library,
            journal: DiagnosticJournal(fileURL: scratch.directory.appending(path: "journal.jsonl"), key: SymmetricKey(size: .bits256)),
            developer: DeveloperDiagnostics(),
            context: { [:] },
            log: log,
            aiLog: ai,
            parent: scratch.directory.appending(path: "bundles")
        )

        let folder = try await builder.prepareFolder(
            DebugBundleRequest(recordingIDs: [recording.id], includesAudio: false),
            progress: { _ in }
        )
        let entry = try #require(
            try FileManager.default.contentsOfDirectory(at: folder.appending(path: "recordings"), includingPropertiesForKeys: nil).first
        )

        #expect(!FileManager.default.fileExists(atPath: entry.appending(path: "audio-microphone.wav").path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: entry.appending(path: "transcript.txt").path(percentEncoded: false)))
    }

    @Test
    func theBundleIsOneZipFile() throws {
        let scratch = try Scratch()
        let folder = scratch.directory.appending(path: "Still-Debug-test", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appending(path: "README.txt"))

        let zip = try DebugBundleBuilder.zip(folder, in: scratch.directory)

        #expect(zip.lastPathComponent == "Still-Debug-test.zip")
        #expect(try Data(contentsOf: zip).prefix(2) == Data("PK".utf8))
    }

    @Test
    func theTranscriptShowsTimesSpeakersAndCorrections() {
        let speaker = Speaker(name: "Anna", origin: .system, isYou: false)
        var segment = TranscriptSegment(start: 61.5, end: 63, text: "ship friday", language: "en", confidence: 0.9, speakerID: speaker.id)
        segment.correction = "ship Friday"
        let recording = Recording(title: "Plan", transcript: "ship friday", segments: [segment], speakers: [speaker], duration: 70)

        let text = DebugBundleBuilder.transcript(of: recording)

        #expect(text.contains("[01:01.50–01:03.00] Anna (conf 0.90, en): ship friday"))
        #expect(text.contains("corrected: ship Friday"))
    }

    private func streams(in directory: URL) throws -> (DevLogStream, DevLogStream) {
        let key = SymmetricKey(size: .bits256)
        let log = DevLogStream(category: "test-main")
        let ai = DevLogStream(category: "test-ai")
        log.configure(directory: directory, name: "devlog", key: key)
        ai.configure(directory: directory, name: "ai-trace", key: key)
        log.setEnabled(true)
        ai.setEnabled(true)
        return (log, ai)
    }

    private func makeLibrary(source: FakeDeviceKeySource, audioRoot: URL) async throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let library = Library(
            keyRing: LibraryKeyRing(source: source),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        return library
    }
}

struct AITraceTests {
    @Test
    func aModelCallIsFiledUnderTheRecordingItWorkedOn() async throws {
        let id = UUID()
        let marker = "test.ai.\(UUID().uuidString)"
        DevLog.ai.setEnabled(true)

        AITrace.$recordingID.withValue(id) {
            AITrace.$stage.withValue("title") {
                AITrace.record(marker, ["output": "Budget Review"])
            }
        }
        await DevLog.ai.flush()

        let record = try #require(try DevLog.ai.records { $0.name == marker }.first)
        #expect(record.fields?["recordingID"] == id.uuidString)
        #expect(record.fields?["stage"] == "title")
    }
}

private actor Answers {
    private var remaining: [BuildChannel]

    init(_ answers: [BuildChannel]) {
        remaining = answers
    }

    func next() -> BuildChannel {
        remaining.isEmpty ? .unknown : remaining.removeFirst()
    }
}
