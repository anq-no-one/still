import CoreML
import FluidAudio
import Foundation

struct FluidSpeakerDiarizer: SpeakerDiarizer {
    let pack: ModelPack
    let root: URL

    func turns(in samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn] {
        guard ModelPackInstaller.isInstalled(pack: pack, root: root) else {
            throw SpeakerSeparationError.modelNotInstalled
        }

        let directory = pack.installedDirectory(in: root)
        return try await AutomaticSpeakerDiarizer(
            smallMeeting: SortformerSpeakerDiarizer(model: directory.appending(path: SpeakerModels.smallMeeting)),
            largeMeeting: LSEENDSpeakerDiarizer(model: directory.appending(path: SpeakerModels.largeMeeting))
        )
        .turns(in: samples, sampleRate: sampleRate)
    }
}

struct SortformerSpeakerDiarizer: SpeakerDiarizer {
    let model: URL

    func turns(in samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn] {
        let diarizer = OfflineSortformerDiarizer(config: OfflineSortformerConfig(precision: .palettized))
        try await diarizer.initialize(modelPath: model)
        let config = diarizer.config
        let timeline = try diarizer.processComplete(
            samples,
            sourceSampleRate: sampleRate == config.sampleRate ? nil : Double(sampleRate)
        )
        return SpeakerTurn.turns(in: timeline)
    }
}

struct LSEENDSpeakerDiarizer: SpeakerDiarizer {
    let model: URL

    func turns(in samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn] {
        let diarizer = try LSEENDDiarizer(model: LSEENDModel(modelURL: model))
        let timeline = try diarizer.processComplete(
            samples,
            sourceSampleRate: sampleRate == diarizer.targetSampleRate ? nil : Double(sampleRate)
        )
        return SpeakerTurn.turns(in: timeline)
    }
}

private extension SpeakerTurn {
    static func turns(in timeline: DiarizerTimeline) -> [SpeakerTurn] {
        timeline.speakers.values
            .flatMap { $0.finalizedSegments + $0.tentativeSegments }
            .map { SpeakerTurn(speaker: $0.speakerIndex, start: TimeInterval($0.startTime), end: TimeInterval($0.endTime)) }
            .sorted { $0.start < $1.start }
    }
}

struct FluidVoiceprintExtractor: VoiceprintExtractor {
    static let windowMaskFrames = 589
    static let sampleRate = 16_000

    let pack: ModelPack
    let root: URL

    func voiceprints(for turns: [SpeakerTurn], in samples: [Float], sampleRate: Int) async throws -> [Int: Voiceprint] {
        guard ModelPackInstaller.isInstalled(pack: pack, root: root) else {
            throw SpeakerSeparationError.modelNotInstalled
        }
        guard sampleRate == Self.sampleRate else { throw SpeakerSeparationError.unsupportedSampleRate }

        let model = try MLModel(contentsOf: pack.installedDirectory(in: root).appending(path: SpeakerModels.voiceprint))
        let extractor = EmbeddingExtractor(embeddingModel: model)
        let mask = [Float](repeating: 1, count: Self.windowMaskFrames)

        var prints: [Int: Voiceprint] = [:]
        for (speaker, speakerTurns) in Dictionary(grouping: turns, by: \.speaker) {
            let clips = try VoiceClips.ranges(for: speakerTurns, sampleRate: sampleRate, sampleCount: samples.count)
                .compactMap { range in
                    try extractor.getEmbeddings(audio: Array(samples[range]), masks: [mask]).first.flatMap(Voiceprint.init)
                }
            prints[speaker] = Voiceprint.mean(clips)
        }
        return prints
    }
}
