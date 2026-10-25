import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import Foundation
import Synchronization

/// What one audio track delivered over a window of time: how much, how
/// loud, and whether the stream skipped or stalled. Kept as plain numbers so
/// the audio thread only adds and compares.
struct AudioTapStats: Equatable, Sendable {
    static let silentLevel: Float = 0.001
    static let clippedLevel: Float = 0.999
    static let gapTolerance: Double = 0.002

    var callbacks = 0
    var frames = 0
    var audioSeconds = 0.0
    var gaps = 0
    var gapSeconds = 0.0
    var overlaps = 0
    var maxInterval = 0.0
    var peak: Float = 0
    var sumOfSquares = 0.0
    var measured = 0
    var silent = 0
    var clipped = 0
    var dropped = 0
    var writeErrors = 0
    var windowStartedAt: Double?
    var lastCallbackAt: Double?
    var expectedStart: Double?
    var sampleRate = 0.0

    mutating func delivered(frames count: Int, sampleRate rate: Double, startSeconds: Double?, at uptime: Double) {
        if windowStartedAt == nil { windowStartedAt = uptime }
        if let lastCallbackAt { maxInterval = max(maxInterval, uptime - lastCallbackAt) }
        lastCallbackAt = uptime
        callbacks += 1
        frames += count
        sampleRate = rate
        let duration = rate > 0 ? Double(count) / rate : 0
        audioSeconds += duration
        if let startSeconds {
            if let expectedStart {
                let difference = startSeconds - expectedStart
                if difference > Self.gapTolerance {
                    gaps += 1
                    gapSeconds += difference
                } else if difference < -Self.gapTolerance {
                    overlaps += 1
                }
            }
            expectedStart = startSeconds + duration
        }
    }

    mutating func measure(_ sample: Float) {
        let level = abs(sample)
        peak = max(peak, level)
        sumOfSquares += Double(sample * sample)
        measured += 1
        if level < Self.silentLevel { silent += 1 }
        if level >= Self.clippedLevel { clipped += 1 }
    }

    func isDue(at uptime: Double, every interval: Double) -> Bool {
        guard let windowStartedAt else { return false }
        return uptime - windowStartedAt >= interval
    }

    /// Starts the next window but keeps what continuity checks need.
    mutating func nextWindow() {
        self = AudioTapStats(lastCallbackAt: lastCallbackAt, expectedStart: expectedStart, sampleRate: sampleRate)
    }

    func fields(at uptime: Double) -> [String: String] {
        var fields = [
            "callbacks": String(callbacks),
            "frames": String(frames),
            "sampleRate": String(format: "%.0f", sampleRate),
            "audioS": String(format: "%.3f", audioSeconds),
            "gaps": String(gaps),
            "gapMS": String(format: "%.1f", gapSeconds * 1000),
            "overlaps": String(overlaps),
            "maxIntervalMS": String(format: "%.1f", maxInterval * 1000),
            "peakDBFS": Self.decibels(Double(peak)),
            "rmsDBFS": Self.decibels(measured > 0 ? (sumOfSquares / Double(measured)).squareRoot() : 0),
            "silentPercent": String(format: "%.0f", measured > 0 ? Double(silent) / Double(measured) * 100 : 100),
            "clipped": String(clipped),
            "dropped": String(dropped),
            "writeErrors": String(writeErrors),
        ]
        if let windowStartedAt { fields["wallS"] = String(format: "%.3f", uptime - windowStartedAt) }
        return fields
    }

    static func decibels(_ level: Double) -> String {
        level > 0 ? String(format: "%.1f", 20 * log10(level)) : "-inf"
    }
}

/// Feeds a track's buffers into `AudioTapStats` and writes an `audio.stats`
/// record every few seconds, plus one when the track stops.
final class AudioTapMeter: Sendable {
    let track: String
    private let interval: Double
    private let stream: DevLogStream
    private let stats = Mutex(AudioTapStats())

    init(track: String, interval: Double = 5, stream: DevLogStream = DevLog.main) {
        self.track = track
        self.interval = interval
        self.stream = stream
    }

    func add(_ buffer: AVAudioPCMBuffer, startSeconds: Double?) {
        let now = ProcessInfo.processInfo.systemUptime
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let due = stats.withLock { stats -> [String: String]? in
            stats.delivered(frames: frames, sampleRate: rate, startSeconds: startSeconds, at: now)
            if let samples = buffer.floatChannelData?[0] {
                for index in 0..<frames { stats.measure(samples[index]) }
            } else if let samples = buffer.int16ChannelData?[0] {
                for index in 0..<frames { stats.measure(Float(samples[index]) / 32_768) }
            }
            guard stats.isDue(at: now, every: interval) else { return nil }
            defer { stats.nextWindow() }
            return stats.fields(at: now)
        }
        if let due { emit(due) }
    }

    func dropped() {
        stats.withLock { $0.dropped += 1 }
    }

    func writeFailed() {
        stats.withLock { $0.writeErrors += 1 }
    }

    func flush(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let fields = stats.withLock { stats -> [String: String]? in
            guard stats.callbacks > 0 || stats.dropped > 0 else { return nil }
            defer { stats = AudioTapStats() }
            return stats.fields(at: now)
        }
        guard var fields else { return }
        fields["final"] = reason
        emit(fields)
    }

    private func emit(_ fields: [String: String]) {
        var fields = fields
        fields["track"] = track
        fields.merge(DiagnosticRecording.fields) { first, _ in first }
        stream.append(DevLog.record(.event, "audio.stats", thread: nil, fields: fields))
    }
}

enum AudioDiagnostics {
    static func formatFields(_ format: AVAudioFormat) -> [String: String] {
        [
            "sampleRate": String(format: "%.0f", format.sampleRate),
            "channels": String(format.channelCount),
            "commonFormat": String(describing: format.commonFormat.rawValue),
            "interleaved": String(format.isInterleaved),
        ]
    }

    static func event(_ name: String, _ fields: [String: String] = [:]) {
        DevLog.event(name, fields.merging(DiagnosticRecording.fields) { first, _ in first })
    }

    static func error(_ name: String, _ error: (any Error)?, _ fields: [String: String] = [:]) {
        DevLog.error(name, error, fields.merging(DiagnosticRecording.fields) { first, _ in first })
    }
}

/// Logs every change to where sound comes from: the default input device and
/// device list on Mac, and the audio session's route, interruptions and
/// resets on iPhone and iPad. These are what silently stop a capture.
@MainActor
enum AudioRouteLog {
    private static var started = false
    #if os(macOS)
    private static var listener: AudioObjectPropertyListenerBlock?
    #endif

    static func start() {
        guard !started else { return }
        started = true
        #if os(macOS)
        AudioDiagnostics.event("audio.devices", CoreAudioInputDevices.diagnosticFields())
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            AudioDiagnostics.event("audio.devices.changed", CoreAudioInputDevices.diagnosticFields())
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .global(qos: .utility), listener)
        }
        self.listener = listener
        #else
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        AudioDiagnostics.event("audio.session", sessionFields())
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { note in
            var fields = sessionFields()
            fields["reason"] = String((note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0)
            if let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
                fields["previousInputs"] = previous.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            }
            AudioDiagnostics.event("audio.session.routeChanged", fields)
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { note in
            var fields = sessionFields()
            fields["type"] = String((note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0)
            fields["reason"] = String((note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt) ?? 0)
            fields["options"] = String((note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            AudioDiagnostics.event("audio.session.interrupted", fields)
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { _ in
            AudioDiagnostics.event("audio.session.mediaServicesReset", sessionFields())
        }
        center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session, queue: nil) { note in
            var fields = sessionFields()
            fields["hint"] = String((note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt) ?? 0)
            AudioDiagnostics.event("audio.session.otherAudioHint", fields)
        }
        #endif
    }

    #if os(iOS)
    nonisolated static func sessionFields() -> [String: String] {
        let session = AVAudioSession.sharedInstance()
        return [
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "sampleRate": String(format: "%.0f", session.sampleRate),
            "ioBufferMS": String(format: "%.1f", session.ioBufferDuration * 1000),
            "inputs": session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ","),
            "outputs": session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ","),
            "otherAudioPlaying": String(session.isOtherAudioPlaying),
            "inputAvailable": String(session.isInputAvailable),
        ]
    }
    #endif
}
