import Foundation
import OSLog
#if os(iOS)
import UIKit
#endif

struct DebugAudioSource: Sendable {
    let recordingID: UUID
    let root: URL
    let cipher: LibraryCipher
    let tracks: [AudioTrack]

    func wav(_ track: AudioTrack) throws -> Data {
        try AudioChunkStore.audio(forRecording: recordingID, track: track, in: root, cipher: cipher)
    }

    func manifest(_ track: AudioTrack) throws -> AudioManifest {
        try AudioChunkStore.manifest(
            in: AudioChunkStore.trackDirectory(forRecording: recordingID, track: track, in: root),
            cipher: cipher
        )
    }
}

struct DebugBundleRequest: Sendable {
    var recordingIDs: [UUID]
    var includesAudio: Bool
}

struct DebugBundleRecording: Sendable {
    let recording: Recording
    let audio: DebugAudioSource?
}

/// A zip with everything a developer needs to reproduce what this device saw:
/// the developer log, timings, hangs, MetricKit reports, the current run's
/// system log, and for each chosen recording its original tracks, transcript,
/// note, extracted memory and every model prompt and answer behind them.
@MainActor
struct DebugBundleBuilder {
    let library: Library
    let journal: DiagnosticJournal
    let developer: DeveloperDiagnostics
    let context: @MainActor () -> [String: String]
    var log: DevLogStream = DevLog.main
    var aiLog: DevLogStream = DevLog.ai
    var parent = URL.temporaryDirectory.appending(path: "DebugBundles", directoryHint: .isDirectory)

    func build(_ request: DebugBundleRequest, progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let started = Perf.begin("debugBundle.build")
        let folder = try await prepareFolder(request, progress: progress)
        progress("Compressing")
        let parent = parent
        let zip = try await Task.detached(priority: .userInitiated) {
            try Self.zip(folder, in: parent)
        }.value
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        Perf.end(started, ["bytes": String(size), "recordings": String(request.recordingIDs.count)])
        return zip
    }

    func prepareFolder(_ request: DebugBundleRequest, progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        progress("Flushing logs")
        DevLog.event("debugBundle.requested", ["recordings": String(request.recordingIDs.count), "audio": String(request.includesAudio)])
        await log.flush()
        await aiLog.flush()

        try? FileManager.default.removeItem(at: parent)
        let folder = parent.appending(path: Self.bundleName(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try journal.export(to: folder.appending(path: "journal.txt"))
        let device = deviceInfo()
        let librarySummary = library.storedRecordings.map(Self.summary)
        let chosen = request.recordingIDs.compactMap { id -> DebugBundleRecording? in
            guard let recording = library.storedRecordings.first(where: { $0.id == id }) else { return nil }
            return DebugBundleRecording(
                recording: recording,
                audio: request.includesAudio ? library.debugAudioSource(forRecording: id) : nil
            )
        }
        let sessionStats = Perf.snapshot()
        let metricKit = developer.metricKitDirectory
        let crashes = developer.crashesDirectory

        let report: @Sendable (String) -> Void = { step in Task { @MainActor in progress(step) } }
        let logs = (main: log, ai: aiLog)
        try await Task.detached(priority: .userInitiated) {
            try Self.writeContents(
                to: folder,
                logs: logs,
                device: device,
                librarySummary: librarySummary,
                recordings: chosen,
                sessionStats: sessionStats,
                metricKit: metricKit,
                crashes: crashes,
                progress: report
            )
        }.value
        return folder
    }

    private func deviceInfo() -> [String: String] {
        let environment = Diagnostics.systemEnvironment()
        var info = context()
        info["channel"] = developer.channel.rawValue
        info["appVersion"] = environment.appVersion
        info["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        info["os"] = environment.systemVersion
        info["hardware"] = Self.hardwareModel
        info["physicalMemoryGB"] = String(format: "%.1f", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
        info["processors"] = String(ProcessInfo.processInfo.activeProcessorCount)
        info["thermal"] = ResourceSampler.thermalName(ProcessInfo.processInfo.thermalState)
        info["lowPower"] = String(ProcessInfo.processInfo.isLowPowerModeEnabled)
        info["locale"] = Locale.current.identifier
        info["preferredLanguages"] = Locale.preferredLanguages.joined(separator: ",")
        info["timeZone"] = TimeZone.current.identifier
        info["uptimeSinceLaunchS"] = String(format: "%.0f", DevLogClock.sinceLaunch)
        info["libraryState"] = String(describing: library.state)
        info["recordings"] = String(library.storedRecordings.count)
        info["projects"] = String(library.projects.count)
        info["generatedAt"] = Date.now.formatted(.iso8601)
        #if os(iOS)
        info["device"] = UIDevice.current.model
        info["idiom"] = String(describing: UIDevice.current.userInterfaceIdiom.rawValue)
        #endif
        return info
    }

    private static func summary(_ recording: Recording) -> [String: String] {
        [
            "id": recording.id.uuidString,
            "createdAt": recording.createdAt.formatted(.iso8601),
            "durationS": String(format: "%.0f", recording.duration),
            "segments": String(recording.segments.count),
            "speakers": String(recording.speakers.count),
            "transcriptChars": String(recording.transcript.count),
            "isProcessing": String(recording.isProcessing),
            "isDeleted": String(recording.isDeleted),
            "isArchived": String(recording.isArchived),
            "projectConfirmed": String(recording.isProjectConfirmed),
            "memoryItems": String(recording.memory?.items.count ?? 0),
            "memoryChunks": recording.memory?.run.map { "\($0.completedChunks)/\($0.totalChunks)" } ?? "-",
            "noteSummary": String(recording.note?.summary.count ?? 0),
            "noteDecisions": String(recording.note?.decisions.count ?? 0),
            "noteActions": String(recording.note?.actions.count ?? 0),
            "titleSource": recording.titleSource?.rawValue ?? "-",
            "imported": String(recording.importedFrom != nil),
        ]
    }

    nonisolated private static func writeContents(
        to folder: URL,
        logs: (main: DevLogStream, ai: DevLogStream),
        device: [String: String],
        librarySummary: [[String: String]],
        recordings: [DebugBundleRecording],
        sessionStats: [String: PerfStat],
        metricKit: URL?,
        crashes: URL?,
        progress: @Sendable (String) -> Void
    ) throws {
        let encoder = DevLogStream.plainEncoder
        encoder.outputFormatting.insert(.prettyPrinted)
        try encoder.encode(device).write(to: folder.appending(path: "device.json"))
        try encoder.encode(librarySummary).write(to: folder.appending(path: "library-summary.json"))
        try preferences().write(to: folder.appending(path: "preferences.json"))

        progress("Writing developer log")
        _ = try logs.main.export(to: folder.appending(path: "devlog.jsonl"))
        _ = try logs.ai.export(to: folder.appending(path: "ai-trace.jsonl"))

        progress("Summarising performance")
        let records = try logs.main.records { $0.kind != .sample && $0.kind != .counter }
        try performanceReport(records: records, sessionStats: sessionStats)
            .write(to: folder.appending(path: "performance.txt"), atomically: true, encoding: .utf8)

        progress("Reading system log")
        try systemLog().write(to: folder.appending(path: "oslog-this-launch.txt"), atomically: true, encoding: .utf8)

        if let metricKit, FileManager.default.fileExists(atPath: metricKit.path(percentEncoded: false)) {
            try FileManager.default.copyItem(at: metricKit, to: folder.appending(path: "metrickit", directoryHint: .isDirectory))
        }
        if let crashes, FileManager.default.fileExists(atPath: crashes.path(percentEncoded: false)) {
            try FileManager.default.copyItem(at: crashes, to: folder.appending(path: "crashes", directoryHint: .isDirectory))
        }

        progress("Reading threads and memory")
        try StackSampler.allThreadsReport().write(to: folder.appending(path: "threads.txt"), atomically: true, encoding: .utf8)
        try encoder.encode(BinaryImages.snapshot()).write(to: folder.appending(path: "images.json"))
        try encoder.encode(memorySnapshot()).write(to: folder.appending(path: "memory.json"))

        let recordingsFolder = folder.appending(path: "recordings", directoryHint: .isDirectory)
        for (index, entry) in recordings.enumerated() {
            progress("Recording \(index + 1) of \(recordings.count)")
            try write(entry, into: recordingsFolder, logs: logs, encoder: encoder)
        }

        try readme(recordingCount: recordings.count).write(to: folder.appending(path: "README.txt"), atomically: true, encoding: .utf8)
    }

    nonisolated private static func write(
        _ entry: DebugBundleRecording,
        into parent: URL,
        logs: (main: DevLogStream, ai: DevLogStream),
        encoder: JSONEncoder
    ) throws {
        let recording = entry.recording
        let day = recording.createdAt.formatted(.iso8601.year().month().day())
        let folder = parent.appending(path: "\(day)-\(recording.id.uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try encoder.encode(recording).write(to: folder.appending(path: "recording.json"))
        try transcript(of: recording).write(to: folder.appending(path: "transcript.txt"), atomically: true, encoding: .utf8)
        try RecordingDocument.markdown(for: recording).write(to: folder.appending(path: "note.md"), atomically: true, encoding: .utf8)
        let id = recording.id.uuidString
        _ = try logs.ai.export(to: folder.appending(path: "ai-trace.jsonl")) { $0.fields?["recordingID"] == id }
        _ = try logs.main.export(to: folder.appending(path: "devlog.jsonl")) { $0.fields?["recordingID"] == id }

        guard let audio = entry.audio else { return }
        var tracks: [String: [String: String]] = [:]
        for track in audio.tracks {
            do {
                let wav = try audio.wav(track)
                try wav.write(to: folder.appending(path: "audio-\(track.rawValue).wav"))
                let manifest = try audio.manifest(track)
                tracks[track.rawValue] = [
                    "sampleRate": String(manifest.format.sampleRate),
                    "channels": String(manifest.format.channels),
                    "bitsPerSample": String(manifest.format.bitsPerSample),
                    "startOffsetS": String(manifest.startOffset),
                    "chunkSeconds": String(manifest.chunkSeconds),
                    "isComplete": String(manifest.isComplete),
                    "durationS": String(format: "%.2f", manifest.format.duration(ofBytes: max(0, wav.count - 44))),
                    "bytes": String(wav.count),
                ]
            } catch {
                tracks[track.rawValue] = ["error": String(describing: error)]
            }
        }
        try encoder.encode(tracks).write(to: folder.appending(path: "tracks.json"))
    }

    nonisolated static func transcript(of recording: Recording) -> String {
        let speakers = Dictionary(recording.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func clock(_ seconds: TimeInterval) -> String {
            String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
        }
        var lines = ["# \(recording.title)", "duration \(clock(recording.duration)) · \(recording.segments.count) segments", ""]
        for speaker in recording.speakers {
            lines.append("speaker \(speaker.id.uuidString.prefix(8)) \"\(speaker.name)\" origin=\(speaker.origin?.rawValue ?? "-") you=\(speaker.isYou) source=\(speaker.nameSource?.rawValue ?? "-") suggested=\(speaker.suggestedName ?? "-")")
        }
        lines.append("")
        for segment in recording.segments {
            let speaker = segment.speakerID.flatMap { speakers[$0] }
            let confidence = segment.confidence.map { String(format: "%.2f", $0) } ?? "-"
            var line = "[\(clock(segment.start))–\(clock(segment.end))] \(speaker?.name ?? "?") (conf \(confidence), \(segment.language ?? "-")): \(segment.text)"
            if let correction = segment.correction { line += "  ⇒ corrected: \(correction)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated private static func performanceReport(records: [DevLogRecord], sessionStats: [String: PerfStat]) -> String {
        var allStats: [String: PerfStat] = [:]
        var interactions: [String: PerfStat] = [:]
        var hangs: [DevLogRecord] = []
        for record in records {
            guard let ms = record.ms else { continue }
            switch record.kind {
            case .span:
                allStats[record.name, default: PerfStat()].add(ms, onMain: record.thread == "main")
            case .interaction:
                let key = record.fields?["stage"].map { "\(record.name) → \($0)" } ?? record.name
                interactions[key, default: PerfStat()].add(ms, onMain: true)
            case .hang:
                hangs.append(record)
            default:
                break
            }
        }
        let hangText = hangs.sorted { ($0.ms ?? 0) > ($1.ms ?? 0) }.prefix(200).map { hang in
            String(format: "%8.0fms ", hang.ms ?? 0) + "\(hang.at.formatted(.iso8601)) \(hang.fields?["severity"] ?? "") blockedBy=\(hang.fields?["blockedBy"] ?? "unknown")"
        }
        return """
            Still performance report
            Times are wall-clock milliseconds. onMain counts spans that started on the main thread.

            == Spans, all stored sessions ==
            \(Perf.summary(allStats))
            == Spans, this launch ==
            \(Perf.summary(sessionStats))
            == What a person waited for (input → frame committed, or → named milestone) ==
            \(Perf.summary(interactions))
            == Main thread unresponsive, worst first (\(hangs.count) total) ==
            \(hangText.joined(separator: "\n"))

            """
    }

    nonisolated private static func systemLog() -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(timeIntervalSinceLatestBoot: 0))
        else { return "OSLogStore unavailable\n" }
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(entry.date.formatted(.iso8601)) [\(entry.subsystem):\(entry.category)] \(entry.level.rawValue) \(entry.composedMessage)")
            if lines.count >= 200_000 { break }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private struct MemorySnapshot: Encodable {
        let process: MemoryBreakdown
        let probes: [String: String]
        let liveObjects: [String: Int]
        let threads: [ThreadUsage]
    }

    nonisolated private static func memorySnapshot() -> MemorySnapshot {
        MemorySnapshot(
            process: ProcessProbe.memory(),
            probes: ResourceProbes.read(),
            liveObjects: LiveObjects.snapshot(),
            threads: ProcessProbe.threads()
        )
    }

    nonisolated private static func preferences() throws -> Data {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        let described = domain.mapValues { value -> String in
            if let data = value as? Data { return "<\(data.count) bytes>" }
            return String(describing: value).prefix(2000).description
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(described)
    }

    nonisolated static func zip(_ folder: URL, in parent: URL) throws -> URL {
        let destination = parent.appending(path: "\(folder.lastPathComponent).zip")
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        try? FileManager.default.removeItem(at: folder)
        return destination
    }

    nonisolated private static func readme(recordingCount: Int) -> String {
        """
        Still debug bundle

        device.json           build, channel, OS, hardware, model availability
        library-summary.json  every recording's shape (no content)
        preferences.json      app preferences (keys and secrets live in the Keychain, not here)
        journal.txt           90-day diagnostic journal
        devlog.jsonl          developer log: events, errors, spans (ms, thread, cpuMS), interactions, hangs, resource samples
        ai-trace.jsonl        every on-device model call: prompt, raw output, timing, and validation outcome
        performance.txt       span percentiles, interaction waits, worst main-thread hangs
        oslog-this-launch.txt the system log for this launch, including frameworks
        metrickit/            MetricKit metric and diagnostic payloads (crashes, hangs with call stacks)
        crashes/              what earlier launches left when they crashed: signal or exception, stack, images
        threads.txt           every thread's name, CPU and call stack when the bundle was made
        images.json           loaded binaries with UUID and load address, for atos with the build's dSYM
        memory.json           memory breakdown, MLX memory, live objects per type, per-thread CPU
        recordings/           \(recordingCount) recording(s): original tracks as WAV, recording.json,
                              transcript.txt with timings and speakers, note.md, per-recording ai-trace and devlog

        """
    }

    private static func bundleName() -> String {
        let environment = Diagnostics.systemEnvironment()
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        return "Still-Debug-\(environment.deviceClass)-\(environment.appVersion)-\(build)-\(stamp)"
    }

    private static var hardwareModel: String {
        var size = 0
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        sysctlbyname(key, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname(key, &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
