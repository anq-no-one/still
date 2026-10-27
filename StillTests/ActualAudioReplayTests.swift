import Foundation
import Testing
@testable import Still

@Suite(.serialized)
struct ActualAudioReplayTests {
    struct Configuration: Decodable {
        let recordingDirectory: URL
        let mixedAudio: URL
        let modelRoot: URL
        let outputDirectory: URL
        var iterations: Int = 2
        var transcribe: Bool = true
    }

    @Test
    func replaysPrivateAudioThroughProductionServices() async throws {
        guard let path = ProcessInfo.processInfo.environment["STILL_REPLAY_CONFIG"],
              !path.isEmpty, !path.hasPrefix("$(") else { return }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: raw.hasSuffix("Z") ? raw : raw + "Z") else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid exported date"))
            }
            return date
        }
        var recording = try decoder.decode(Recording.self, from: Data(contentsOf: config.recordingDirectory.appending(path: "recording.json")))
        let metadata = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: config.recordingDirectory.appending(path: "tracks.json")))
        let tracks = try [AudioTrack.microphone, .system].map { track in
            let pcm = try Self.pcm(at: config.recordingDirectory.appending(path: "audio-\(track.rawValue).wav"))
            return CapturedTrack(track: track, format: .transcription, startOffset: Double(metadata[track.rawValue]?["startOffsetS"] ?? "0") ?? 0, pcm: pcm)
        }
        let mixed = try Self.pcm(at: config.mixedAudio)
        let expectedFrames = tracks.map { Int($0.startOffset * 16_000) + $0.pcm.count / 2 }.max() ?? 0
        try #require(mixed.count / 2 == expectedFrames)
        try Self.verifyMix(mixed, tracks: tracks)
        var measurements: [[String: String]] = []
        func measure(_ stage: String) {
            var fields = ProcessProbe.memory().fields.merging(ResourceProbes.read()) { _, new in new }
            fields["stage"] = stage
            measurements.append(fields)
            print("REPLAY \(stage) footprintMiB=\(fields["footprintMB"] ?? "-") activeMiB=\(fields["mlxActiveMB"] ?? "-") cacheMiB=\(fields["mlxCacheMB"] ?? "-")")
        }
        measure("start")
        if config.transcribe {
            let engine = ParakeetEngine(pack: ModelCatalog.parakeetV3, root: config.modelRoot)
            let result = try await FinalTranscription(transcriber: ParakeetOfflineTranscriber(engine: engine)).run(
                tracks: tracks, checkpoints: MemoryCheckpointStore()
            )
            #expect(!result.segments.isEmpty)
            #expect(Set(result.speakers.map(\.origin)).count == 2)
            recording.segments = result.segments
            recording.speakers = result.speakers
            recording.transcript = result.segments.plainText
            measure("transcription")
            try Self.write(recording, to: config.outputDirectory.appending(path: "transcribed.json"))
        } else {
            let people = [Speaker.forTrack(.microphone), Speaker.forTrack(.system)]
            let original = Dictionary(recording.speakers.map { ($0.id, $0.origin) }, uniquingKeysWith: { first, _ in first })
            recording.segments = recording.segments.map { segment in
                guard let origin = segment.speakerID.flatMap({ original[$0] }), let speaker = people.first(where: { $0.origin == origin }) else { return segment }
                return segment.attributed(to: speaker)
            }
            recording.speakers = people
        }
        let separation = SpeakerSeparation(
            diarizer: FluidSpeakerDiarizer(pack: ModelCatalog.speakerSeparation, root: config.modelRoot),
            voiceprints: FluidVoiceprintExtractor(pack: ModelCatalog.speakerSeparation, root: config.modelRoot)
        )
        let separated = await separation.separate(TranscriptionResult(segments: recording.segments, speakers: recording.speakers), tracks: tracks)
        recording.segments = separated.segments
        recording.speakers = separated.speakers
        #expect(recording.speakers.count > 2)
        measure("speakers-\(recording.speakers.count)")
        try Self.write(recording, to: config.outputDirectory.appending(path: "separated.json"))
        let pack = ModelCatalog.meetingMemoryLarge
        let model = LocalLanguageModel(directory: pack.installedDirectory(in: config.modelRoot))
        let extractor = LocalModelExtractor(pack: pack, root: config.modelRoot, model: model)
        var idleFootprints: [Double] = []
        for iteration in 1...max(1, config.iterations) {
            recording.note = try await LocalModelNoteGenerator(model: model).note(template: .meeting, segments: recording.segments)
            #expect(recording.note?.generation?.source == .model)
            #expect(NoteSchema.isGrounded(try #require(recording.note), in: recording.segments))
            #expect(recording.note?.summary.isEmpty == false)
            measure("note-\(iteration)")
            let windows = ExtractionWindows.windows(of: ExtractionSegment.segments(of: recording))
            var kept: [MemoryItem] = []
            var withheld = 0
            for (index, window) in windows.enumerated() {
                let candidates = try await extractor.candidates(from: window, language: "en")
                let outcome = ProvenanceValidator().validate(candidates, against: recording.segments, speakers: recording.speakers)
                kept += outcome.items
                withheld += outcome.withheld
                measure("memory-\(iteration)-\(index + 1)")
            }
            try Self.write(kept, to: config.outputDirectory.appending(path: "memory-\(iteration).json"))
            try Self.write(recording, to: config.outputDirectory.appending(path: "result-\(iteration).json"))
            try RecordingDocument.markdown(for: recording).write(to: config.outputDirectory.appending(path: "note-\(iteration).md"), atomically: true, encoding: .utf8)
            measure("idle-\(iteration)")
            idleFootprints.append(ProcessProbe.memory().footprintMB)
            print("REPLAY iteration=\(iteration) speakers=\(recording.speakers.count) memoryKept=\(kept.count) withheld=\(withheld)")
            try Self.write(measurements, to: config.outputDirectory.appending(path: "measurements.json"))
        }
        if idleFootprints.count > 1, let first = idleFootprints.first, let last = idleFootprints.last {
            #expect(last <= first * 1.2 + 128)
        }
    }

    private static func pcm(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        try #require(data.count >= 44)
        try #require(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        try #require(String(data: data[8..<16], encoding: .ascii) == "WAVEfmt ")
        try #require(Array(data[16..<36]) == [16, 0, 0, 0, 1, 0, 1, 0, 128, 62, 0, 0, 0, 125, 0, 0, 2, 0, 16, 0])
        try #require(String(data: data[36..<40], encoding: .ascii) == "data")
        let bytes = (0..<4).reduce(0) { $0 | Int(data[40 + $1]) << ($1 * 8) }
        try #require(bytes == data.count - 44)
        return Data(data.dropFirst(44))
    }

    private static func verifyMix(_ mixed: Data, tracks: [CapturedTrack]) throws {
        var sum = [Int32](repeating: 0, count: mixed.count / 2)
        for track in tracks {
            let offset = Int(track.startOffset * 16_000)
            track.pcm.withUnsafeBytes { bytes in
                for (index, sample) in bytes.bindMemory(to: Int16.self).enumerated() {
                    sum[index + offset] += Int32(sample)
                }
            }
        }
        let matches = mixed.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).enumerated().allSatisfy { index, value in
                value == Int16(clamping: sum[index])
            }
        }
        #expect(matches)
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
