import Foundation
import Testing
@testable import Still

struct DebugBundleSummaryTests {
    private let moment = Date(timeIntervalSince1970: 1_761_400_000)

    private func record(_ kind: DevLogRecord.Kind, _ name: String, at offset: TimeInterval, ms: Double? = nil, _ fields: [String: String] = [:]) -> DevLogRecord {
        DevLogRecord(at: moment.addingTimeInterval(offset), uptime: offset, kind: kind, name: name, ms: ms, thread: nil, fields: fields)
    }

    @Test
    func theTestersNoteAndAttachmentsComeFirst() {
        let text = DebugBundleSummary.make(.init(note: "Names swapped after sync", attachments: ["attachment-1.png"]))

        #expect(text.contains("> Names swapped after sync"))
        #expect(text.contains("`attachments/attachment-1.png`"))
    }

    @Test
    func aMarkedMomentShowsOnlyWhatHappenedAroundIt() {
        let records = [
            record(.event, "audio.mic.configurationChanged", at: -5, ["engineRunning": "false"]),
            record(.event, "sync.cloudKit.pulled", at: -90),
        ]
        let marker = ProblemMarker(at: moment, reason: .tester, note: "mic stopped", screen: "library")

        let text = DebugBundleSummary.make(.init(records: records, markers: [marker]))

        #expect(text.contains("tester: mic stopped"))
        #expect(text.contains("-5.0s event audio.mic.configurationChanged"))
        #expect(!text.contains("sync.cloudKit.pulled"))
    }

    @Test
    func theWorstHangsAreListedWithTheirStacks() {
        let records = [
            record(.hang, "main.unresponsive", at: 0, ms: 300, ["severity": "stall"]),
            record(.hang, "main.unresponsive", at: 10, ms: 2_400, ["severity": "hang", "blockedBy": "semantic.update", "stack": "0x100004000 0x100004100"]),
        ]

        let text = DebugBundleSummary.make(.init(records: records))
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("- ") && $0.contains(" ms") }

        #expect(lines.first?.contains("2400 ms blockedBy semantic.update stack 0x100004000") == true)
        #expect(text.contains("hang 1 · stall 1"))
    }

    @Test
    func audioTroubleIsAddedUpPerRecordingAndTrack() {
        let recording = UUID()
        let records = [
            record(.event, "audio.stats", at: 0, ["recordingID": recording.uuidString, "track": "system", "audioS": "5", "gaps": "1", "gapMS": "250", "dropped": "2", "silentPercent": "100"]),
            record(.event, "audio.stats", at: 5, ["recordingID": recording.uuidString, "track": "system", "audioS": "5", "gaps": "2", "gapMS": "100", "dropped": "0", "silentPercent": "100"]),
            record(.error, "audio.system.streamStopped", at: 6, ["error": "display slept"]),
        ]

        let text = DebugBundleSummary.make(.init(records: records))

        #expect(text.contains("\(recording.uuidString.prefix(8)) system: 10 s audio, 3 gaps (350 ms)"))
        #expect(text.contains("2 dropped"))
        #expect(text.contains("audio.system.streamStopped: display slept"))
    }

    @Test
    func syncFailuresAreCountedByTheirCloudKitCode() {
        let records = [
            record(.error, "sync.cloudKit.failed", at: 0, ["ckError": "quotaExceeded"]),
            record(.error, "sync.cloudKit.failed", at: 60, ["ckError": "quotaExceeded"]),
            record(.span, "sync.run", at: 61, ms: 800, ["pulled": "recording=3", "pushed": "0", "devices": "2", "step": "push", "error": "unreachable"]),
        ]

        let text = DebugBundleSummary.make(.init(records: records))

        #expect(text.contains("- quotaExceeded ×2"))
        #expect(text.contains("1 sync runs, 1 failed"))
        #expect(text.contains("stopped at push"))
    }

    @Test
    func memoryShowsThePeakAndWhatWasStillAlive() {
        let records = [
            record(.sample, "resources", at: 0, ["footprintMB": "300.0", "cpuPercent": "10"]),
            record(.sample, "resources", at: 5, ["footprintMB": "1450.5", "cpuPercent": "95", "topThreads": "main:90"]),
            record(.counter, "liveObjects", at: 6, ["LiveTranscriber": "2", "MacAudioRecorder": "0"]),
        ]

        let text = DebugBundleSummary.make(.init(records: records))

        #expect(text.contains("peak footprint 1450 MB"))
        #expect(text.contains("LiveTranscriber×2"))
        #expect(!text.contains("MacAudioRecorder×"))
        #expect(text.contains("worst 95 %"))
    }

    @Test
    func anAbruptEndingAfterMemoryPressureReadsAsAMemoryKill() {
        let records = [
            record(.sample, "resources", at: 0, ["footprintMB": "2900.0"]),
            record(.event, "memory.pressure", at: 1, ["level": "critical", "footprintMB": "2950.0"]),
            record(.event, "session.start", at: 120, ["previousSessionEndedAbruptly": "true"]),
        ]

        let text = DebugBundleSummary.make(.init(records: records))

        #expect(text.contains("last footprint 2900.0 MB"))
        #expect(text.contains("likely killed for memory"))
    }

    @Test
    func errorsPointToTheSourceTheyCameFrom() {
        let records = [
            record(.error, "audio.chunk.writeFailed", at: 0, ["error": "disk full"]),
            record(.error, "audio.chunk.writeFailed", at: 1, ["error": "disk full"]),
        ]

        let text = DebugBundleSummary.make(.init(records: records))

        #expect(text.contains("- audio.chunk.writeFailed ×2"))
        #expect(text.contains("| `audio.*` | Still/Audio/"))
        #expect(!text.contains("| `sync.*`"))
    }
}
