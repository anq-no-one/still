import FluidAudio
import Foundation

actor ParakeetEngine {
    static let sampleRate = 16_000

    private let pack: ModelPack
    private let root: URL
    private var manager: AsrManager?

    init(pack: ModelPack, root: URL) {
        self.pack = pack
        self.root = root
    }

    func words(in samples: [Float]) async throws -> [SpokenWord] {
        guard samples.count >= Self.sampleRate / 4 else { return [] }

        let manager = try await loadedManager()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await manager.transcribe(samples, decoderState: &state)
        } catch {
            throw TranscriptionError.recognitionFailed
        }

        let timings = result.tokenTimings ?? []
        return buildWordTimings(from: timings).map { word in
            let tokens = timings.filter { $0.startTime >= word.startTime && $0.endTime <= word.endTime }
            let confidence = tokens.isEmpty ? Double(result.confidence) : tokens.map { Double($0.confidence) }.reduce(0, +) / Double(tokens.count)
            return SpokenWord(text: word.word, start: word.startTime, end: word.endTime, confidence: confidence)
        }
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }

        guard ModelPackInstaller.isInstalled(pack: pack, root: root) else {
            throw TranscriptionError.modelNotInstalled
        }

        let directory = root.appending(path: "\(pack.id)/\(pack.version)", directoryHint: .isDirectory)
        do {
            let models = try AsrModels.loadLocal(from: directory)
            let manager = AsrManager()
            try await manager.loadModels(models)
            self.manager = manager
            return manager
        } catch {
            throw TranscriptionError.recognitionFailed
        }
    }
}

struct SpokenWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double
}
