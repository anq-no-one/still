import Foundation

/// The first page anyone, person or agent, reads in a bundle: what the
/// tester said, the moments they marked with what happened around them,
/// and every kind of trouble the log holds, worst first, with where in the
/// source each kind of record comes from.
enum DebugBundleSummary {
    struct Input {
        var device: [String: String] = [:]
        var note = ""
        var attachments: [String] = []
        var records: [DevLogRecord] = []
        var markers: [ProblemMarker] = []
        var crashes: [CrashReport] = []
    }

    static let sourceMap: [(prefix: String, directory: String)] = [
        ("audio.", "Still/Audio/ (MicrophoneInput, SystemAudioRecorder, AudioChunkStore, AudioDiagnostics)"),
        ("live.", "Still/Services/LiveTranscriber.swift"),
        ("parakeet.", "Still/Services/ParakeetEngine.swift"),
        ("transcribe.", "Still/Services/FinalTranscription.swift"),
        ("record.", "Still/Workflow/ (RecordingCoordinator, RecordingWorkflow, RecordingFinalizer)"),
        ("finalize.", "Still/Workflow/RecordingFinalizer.swift"),
        ("call.", "Still/Automation/ (AutomaticRecording, CallActivityWatcher, CallEndWatch)"),
        ("browser.", "Still/Automation/BrowserMeetings.swift"),
        ("sync.", "Still/Sync/ (SyncEngine, CloudKitSyncTransport, AudioChunkSync, NearbySync)"),
        ("model.", "Still/Models/ModelPackInstaller.swift"),
        ("mlx.", "Still/Intelligence/LocalModelExtractor.swift"),
        ("memory.", "Still/Intelligence/MemoryExtraction.swift, Still/Diagnostics/MemoryPressureMonitor.swift"),
        ("mcp.", "Still/MCP/"),
        ("import.", "Still/Import/MediaImporter.swift"),
        ("library.", "Still/Storage/Library.swift"),
        ("semantic.", "Still/Search/SemanticIndex.swift"),
        ("detail.", "Still/Views/RecordingDetailView.swift"),
        ("bugReport.", "Still/Diagnostics/BugReport.swift, Still/Sync/CloudKitBugReportTransport.swift"),
        ("main.unresponsive", "Still/Diagnostics/Responsiveness.swift (MainThreadWatchdog); stacks in threads.txt and symbolicated/"),
        ("crash.", "Still/Diagnostics/CrashMarker.swift; crashes/"),
    ]

    static func make(_ input: Input) -> String {
        var out: [String] = ["# Still bug report summary", ""]
        out += header(input.device)
        out += note(input)
        out += markers(input)
        out += crashes(input)
        out += hangs(input.records)
        out += memory(input.records)
        out += cpu(input.records)
        out += audio(input.records)
        out += sync(input.records)
        out += errors(input.records)
        out += whereToLook(input.records)
        return out.joined(separator: "\n") + "\n"
    }

    private static func header(_ device: [String: String]) -> [String] {
        let keys = ["channel", "appVersion", "build", "os", "hardware", "physicalMemoryGB", "thermal", "lowPower", "recordings", "generatedAt"]
        let line = keys.compactMap { key in device[key].map { "\(key) \($0)" } }.joined(separator: " · ")
        return [line, ""]
    }

    private static func note(_ input: Input) -> [String] {
        guard !input.note.isEmpty || !input.attachments.isEmpty else { return [] }
        var lines = ["## What the tester said", ""]
        if !input.note.isEmpty { lines += input.note.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" } }
        if !input.attachments.isEmpty {
            lines += ["", "Attached: " + input.attachments.map { "`attachments/\($0)`" }.joined(separator: ", ")]
        }
        return lines + [""]
    }

    private static func markers(_ input: Input) -> [String] {
        guard !input.markers.isEmpty else { return [] }
        var lines = ["## Marked moments", ""]
        for marker in input.markers.sorted(by: { $0.at < $1.at }) {
            lines.append("### \(stamp(marker.at)) — \(marker.reason.rawValue)\(marker.note.isEmpty ? "" : ": \(marker.note)") (screen \(marker.screen))")
            lines.append("")
            let window = input.records.filter {
                abs($0.at.timeIntervalSince(marker.at)) <= 30 && $0.kind != .sample && $0.kind != .counter && $0.kind != .interaction
            }
            lines += window.prefix(60).map { "    " + compact($0, relativeTo: marker.at) }
            if window.count > 60 { lines.append("    … \(window.count - 60) more within ±30 s") }
            lines.append("")
        }
        return lines
    }

    private static func crashes(_ input: Input) -> [String] {
        let abrupt = input.records.filter { $0.name == "session.start" && $0.fields?["previousSessionEndedAbruptly"] == "true" }
        guard !input.crashes.isEmpty || !abrupt.isEmpty else { return [] }
        var lines = ["## Crashes and abrupt endings", ""]
        for crash in input.crashes {
            lines.append("- crash \(crash.at.map(stamp) ?? "?"): \(crash.title) — \(crash.backtrace?.addresses.count ?? 0) frames in crashes/")
        }
        for start in abrupt {
            let lastSample = input.records.last { $0.kind == .sample && $0.at < start.at }
            let footprint = lastSample?.fields?["footprintMB"].map { ", last footprint \($0) MB at \(stamp(lastSample!.at))" } ?? ""
            let pressure = input.records.contains { $0.name.hasPrefix("memory.") && $0.kind == .event && $0.at < start.at && start.at.timeIntervalSince($0.at) < 600 }
            lines.append("- launch \(stamp(start.at)) found the previous session ended without going to the background\(footprint)\(pressure ? "; memory pressure shortly before — likely killed for memory" : "")")
        }
        return lines + [""]
    }

    private static func hangs(_ records: [DevLogRecord]) -> [String] {
        let hangs = records.filter { $0.kind == .hang }
        guard !hangs.isEmpty else { return [] }
        let bySeverity = Dictionary(grouping: hangs) { $0.fields?["severity"] ?? "?" }.mapValues(\.count)
        var lines = ["## Main thread unresponsive", "", bySeverity.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "), ""]
        for hang in hangs.sorted(by: { ($0.ms ?? 0) > ($1.ms ?? 0) }).prefix(10) {
            let blocked = hang.fields?["blockedBy"].map { " blockedBy \($0)" } ?? ""
            let stack = hang.fields?["stack"].map { " stack " + $0.split(separator: " ").prefix(6).joined(separator: " ") + " …" } ?? ""
            lines.append("- \(stamp(hang.at)) \(Int(hang.ms ?? 0)) ms\(blocked)\(stack)")
        }
        return lines + ["", "Stacks are raw addresses; `bin/debug-bundle.sh` symbolicates them into symbolicated/hangs.txt.", ""]
    }

    private static func memory(_ records: [DevLogRecord]) -> [String] {
        let samples = records.filter { $0.kind == .sample && $0.name == "resources" }
        guard !samples.isEmpty else { return [] }
        let footprints = samples.compactMap { sample in sample.fields?["footprintMB"].flatMap(Double.init).map { (sample.at, $0) } }
        guard let peak = footprints.max(by: { $0.1 < $1.1 }) else { return [] }
        var lines = ["## Memory", "", "- peak footprint \(Int(peak.1)) MB at \(stamp(peak.0))"]
        if let first = footprints.first, let last = footprints.last {
            lines.append("- first sample \(Int(first.1)) MB, last \(Int(last.1)) MB")
        }
        let mlx = samples.compactMap { $0.fields?["mlxActiveMB"].flatMap(Double.init) }.max()
        if let mlx { lines.append("- MLX active memory peaked at \(Int(mlx)) MB") }
        let pressure = records.filter { $0.name == "memory.pressure" || $0.name == "memory.warning" }
        for event in pressure.prefix(10) {
            lines.append("- \(event.name) \(event.fields?["level"] ?? "") at \(stamp(event.at)), footprint \(event.fields?["footprintMB"] ?? "?") MB")
        }
        if let live = records.last(where: { $0.name == "liveObjects" })?.fields {
            let held = live.filter { (Int($0.value) ?? 0) > 0 }.sorted { $0.key < $1.key }
            if !held.isEmpty {
                lines.append("- still alive at the last sample: " + held.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
            }
        }
        return lines + [""]
    }

    private static func cpu(_ records: [DevLogRecord]) -> [String] {
        let samples = records.filter { $0.kind == .sample && $0.name == "resources" }
        let busy = samples.filter { (Double($0.fields?["cpuPercent"] ?? "") ?? 0) >= 80 }
        let executor = samples.compactMap { $0.fields?["executorMS.userInitiated"].flatMap(Double.init) }.max()
        guard !busy.isEmpty || (executor ?? 0) >= 50 else { return [] }
        var lines = ["## CPU", ""]
        if !busy.isEmpty {
            var longest = 0
            var current = 0
            for sample in samples {
                current = (Double(sample.fields?["cpuPercent"] ?? "") ?? 0) >= 80 ? current + 1 : 0
                longest = max(longest, current)
            }
            lines.append("- \(busy.count) samples at 80 % or more; longest run about \(longest * 5) s")
            if let worst = busy.max(by: { (Double($0.fields?["cpuPercent"] ?? "") ?? 0) < (Double($1.fields?["cpuPercent"] ?? "") ?? 0) }) {
                lines.append("- worst \(worst.fields?["cpuPercent"] ?? "?") % at \(stamp(worst.at)): \(worst.fields?["topThreads"] ?? "")")
            }
        }
        if let executor, executor >= 50 {
            lines.append("- work waited up to \(Int(executor)) ms for a cooperative-pool thread (something blocks the pool)")
        }
        return lines + [""]
    }

    private static func audio(_ records: [DevLogRecord]) -> [String] {
        let stats = records.filter { $0.name == "audio.stats" }
        let events = records.filter {
            ["audio.mic.configurationChanged", "audio.system.streamStopped", "audio.devices.changed", "audio.session.routeChanged",
             "audio.session.interrupted", "audio.mic.endedByInterruption", "audio.system.startFailed", "audio.mic.engineStartFailed",
             "audio.chunk.writeFailed", "audio.mic.preferredDeviceMissing"].contains($0.name)
        }
        guard !stats.isEmpty || !events.isEmpty else { return [] }
        var lines = ["## Audio", ""]
        let groups = Dictionary(grouping: stats) { "\($0.fields?["recordingID"]?.prefix(8) ?? "none") \($0.fields?["track"] ?? "?")" }
        for (key, group) in groups.sorted(by: { $0.key < $1.key }) {
            func total(_ field: String) -> Double { group.reduce(0) { $0 + (Double($1.fields?[field] ?? "") ?? 0) } }
            let silent = group.compactMap { Double($0.fields?["silentPercent"] ?? "") }
            let maxInterval = group.compactMap { Double($0.fields?["maxIntervalMS"] ?? "") }.max() ?? 0
            lines.append(
                "- \(key): \(String(format: "%.0f", total("audioS"))) s audio, \(Int(total("gaps"))) gaps (\(Int(total("gapMS"))) ms), longest stall \(Int(maxInterval)) ms, \(Int(total("dropped"))) dropped, \(Int(total("writeErrors"))) write errors, \(Int(total("clipped"))) clipped, silent \(silent.isEmpty ? "?" : String(format: "%.0f", silent.reduce(0, +) / Double(silent.count))) % on average"
            )
        }
        for event in events.prefix(20) {
            lines.append("- \(stamp(event.at)) \(event.name)\(event.fields?["error"].map { ": \($0.prefix(140))" } ?? "")")
        }
        return lines + [""]
    }

    private static func sync(_ records: [DevLogRecord]) -> [String] {
        let runs = records.filter { $0.name == "sync.run" }
        let failures = records.filter { $0.kind == .error && $0.name.hasPrefix("sync.") }
        let partial = records.filter { $0.name.hasPrefix("sync.cloudKit.") && ($0.fields?["failed"] != nil || $0.fields?["lookupFailed"] != nil) }
        guard !runs.isEmpty || !failures.isEmpty || !partial.isEmpty else { return [] }
        var lines = ["## Sync", "", "- \(runs.count) sync runs, \(runs.filter { $0.fields?["error"] != nil }.count) failed"]
        let byCode = Dictionary(grouping: failures) { $0.fields?["ckError"] ?? $0.fields?["errorCode"] ?? $0.name }.mapValues(\.count)
        for (code, count) in byCode.sorted(by: { $0.value > $1.value }) {
            lines.append("- \(code) ×\(count)")
        }
        for record in partial.suffix(5) {
            lines.append("- \(stamp(record.at)) \(record.name): \(record.fields?["failed"] ?? record.fields?["lookupFailed"] ?? "")")
        }
        if let last = runs.last {
            lines.append("- last run \(stamp(last.at)): pulled \(last.fields?["pulled"] ?? "?"), pushed \(last.fields?["pushed"] ?? "?"), devices \(last.fields?["devices"] ?? "?"), stopped at \(last.fields?["step"] ?? "?")")
        }
        return lines + [""]
    }

    private static func errors(_ records: [DevLogRecord]) -> [String] {
        let errors = records.filter { $0.kind == .error }
        guard !errors.isEmpty else { return [] }
        var lines = ["## Errors by name", ""]
        for (name, group) in Dictionary(grouping: errors, by: \.name).sorted(by: { $0.value.count > $1.value.count }) {
            let last = group.last
            lines.append("- \(name) ×\(group.count), first \(stamp(group.first!.at)), last \(stamp(last!.at)): \(last?.fields?["error"]?.prefix(160) ?? "")")
        }
        return lines + [""]
    }

    private static func whereToLook(_ records: [DevLogRecord]) -> [String] {
        let names = Set(records.filter { $0.kind == .error || $0.kind == .hang }.map(\.name))
        let relevant = sourceMap.filter { entry in names.contains { $0.hasPrefix(entry.prefix) } }
        guard !relevant.isEmpty else { return [] }
        return ["## Where to look", "", "| Records | Source |", "|---|---|"]
            + relevant.map { "| `\($0.prefix)*` | \($0.directory) |" }
            + [""]
    }

    private static func compact(_ record: DevLogRecord, relativeTo moment: Date) -> String {
        let offset = record.at.timeIntervalSince(moment)
        let ms = record.ms.map { String(format: " %.0fms", $0) } ?? ""
        let fields = (record.fields ?? [:]).filter { !["stack", "stackProfile"].contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.prefix(80))" }
            .joined(separator: " ")
        return String(format: "%+6.1fs ", offset) + "\(record.kind.rawValue) \(record.name)\(ms) \(fields)"
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
    }
}
