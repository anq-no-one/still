import AVFoundation
import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import Still

struct AudioTapStatsTests {
    @Test
    func aJumpInSampleTimeCountsAsAGap() {
        var stats = AudioTapStats()

        stats.delivered(frames: 1_600, sampleRate: 16_000, startSeconds: 10.0, at: 1)
        stats.delivered(frames: 1_600, sampleRate: 16_000, startSeconds: 10.1, at: 1.1)
        stats.delivered(frames: 1_600, sampleRate: 16_000, startSeconds: 10.45, at: 1.45)

        #expect(stats.gaps == 1)
        #expect(abs(stats.gapSeconds - 0.25) < 0.0001)
        #expect(stats.overlaps == 0)
    }

    @Test
    func audioThatRepeatsEarlierTimeCountsAsAnOverlap() {
        var stats = AudioTapStats()

        stats.delivered(frames: 1_600, sampleRate: 16_000, startSeconds: 5.0, at: 1)
        stats.delivered(frames: 1_600, sampleRate: 16_000, startSeconds: 5.05, at: 1.1)

        #expect(stats.overlaps == 1)
        #expect(stats.gaps == 0)
    }

    @Test
    func theLongestWaitBetweenCallbacksIsKept() {
        var stats = AudioTapStats()

        stats.delivered(frames: 10, sampleRate: 16_000, startSeconds: nil, at: 1.0)
        stats.delivered(frames: 10, sampleRate: 16_000, startSeconds: nil, at: 1.1)
        stats.delivered(frames: 10, sampleRate: 16_000, startSeconds: nil, at: 1.9)

        #expect(stats.fields(at: 2)["maxIntervalMS"] == "800.0")
    }

    @Test
    func silenceAndClippingAreShareOfMeasuredSamples() {
        var stats = AudioTapStats()

        for _ in 0..<6 { stats.measure(0) }
        for _ in 0..<2 { stats.measure(0.5) }
        for _ in 0..<2 { stats.measure(-1) }
        let fields = stats.fields(at: 0)

        #expect(fields["silentPercent"] == "60")
        #expect(fields["clipped"] == "2")
        #expect(fields["peakDBFS"] == "0.0")
    }

    @Test
    func aNewWindowStartsFreshButStillNoticesTheNextGap() {
        var stats = AudioTapStats()
        stats.delivered(frames: 1_600, sampleRate: 16_000, startSeconds: 0, at: 1)
        stats.measure(0.3)

        stats.nextWindow()
        stats.delivered(frames: 1_600, sampleRate: 16_000, startSeconds: 0.5, at: 1.5)

        #expect(stats.callbacks == 1)
        #expect(stats.measured == 0)
        #expect(stats.gaps == 1)
    }
}

@Suite(.serialized)
struct AudioTapMeterTests {
    @Test
    func aDueWindowIsLoggedUnderTheRecordingBeingCaptured() async throws {
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test")
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))
        stream.setEnabled(true)
        let meter = AudioTapMeter(track: "microphone", interval: 0, stream: stream)
        let recording = UUID()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for index in 0..<160 { buffer.floatChannelData?[0][index] = 0.25 }

        DiagnosticRecording.began(recording)
        meter.add(buffer, startSeconds: 0)
        meter.add(buffer, startSeconds: 0.01)
        DiagnosticRecording.ended(recording)
        await stream.flush()

        let record = try #require(try stream.records().first { $0.name == "audio.stats" })
        #expect(record.fields?["track"] == "microphone")
        #expect(record.fields?["recordingID"] == recording.uuidString)
        #expect(record.fields?["rmsDBFS"] == "-12.0")
    }

    @Test
    func droppedBuffersAreReportedWhenTheTrackStops() async throws {
        let scratch = try Scratch()
        let stream = DevLogStream(category: "test")
        stream.configure(directory: scratch.directory, name: "log", key: SymmetricKey(size: .bits256))
        stream.setEnabled(true)
        let meter = AudioTapMeter(track: "system", stream: stream)

        meter.dropped()
        meter.dropped()
        meter.writeFailed()
        meter.flush(reason: "finished")
        await stream.flush()

        let record = try #require(try stream.records().first { $0.name == "audio.stats" })
        #expect(record.fields?["dropped"] == "2")
        #expect(record.fields?["writeErrors"] == "1")
        #expect(record.fields?["final"] == "finished")
    }

    @Test
    func anotherRecordingEndingLeavesTheCurrentOneTagged() {
        let current = UUID()

        DiagnosticRecording.began(current)
        DiagnosticRecording.ended(UUID())
        let tagged = DiagnosticRecording.id
        DiagnosticRecording.ended(current)

        #expect(tagged == current)
        #expect(DiagnosticRecording.id == nil)
    }
}

struct CloudKitDiagnosticsTests {
    @Test
    func aPartialFailureKeepsTheCodeOfEveryRecordThatFailed() {
        let zone = CKRecordZone.ID(zoneName: "Recordings")
        let partial: [CKRecord.ID: Error] = [
            CKRecord.ID(recordName: "a", zoneID: zone): CKError(.serverRecordChanged),
            CKRecord.ID(recordName: "b", zoneID: zone): CKError(.serverRecordChanged),
            CKRecord.ID(recordName: "c", zoneID: zone): CKError(.quotaExceeded),
        ]
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: partial])

        let fields = CloudKitDiagnostics.fields(for: error)

        #expect(fields["domain"] == CKError.errorDomain)
        #expect(fields["ckError"] == "partialFailure")
        #expect(fields["partialErrors"] == "quotaExceeded=1,serverRecordChanged=2")
    }

    @Test
    func aRateLimitSaysWhenToTryAgain() {
        let error = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0])

        #expect(CloudKitDiagnostics.fields(for: error)["retryAfterS"] == "30")
    }

    @Test
    func failedRecordsInASuccessfulBatchAreCounted() {
        let zone = CKRecordZone.ID(zoneName: "Recordings")
        let results: [CKRecord.ID: Result<Int, any Error>] = [
            CKRecord.ID(recordName: "a", zoneID: zone): .success(1),
            CKRecord.ID(recordName: "b", zoneID: zone): .failure(CKError(.unknownItem)),
        ]

        #expect(CloudKitDiagnostics.failures(results) == "unknownItem=1")
        #expect(CloudKitDiagnostics.failures([CKRecord.ID: Result<Int, any Error>]()) == nil)
    }
}

@MainActor
struct DebugStateRegistryTests {
    @Test
    func theSnapshotAsksEveryPartForItsStateNow() {
        let registry = DebugStateRegistry()
        var phase = "idle"
        registry.register("recording") { ["phase": phase] }
        registry.register("sync") { ["enabled": "true"] }

        phase = "recording"

        #expect(registry.snapshot() == ["recording": ["phase": "recording"], "sync": ["enabled": "true"]])
    }
}
