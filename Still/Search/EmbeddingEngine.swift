import Foundation
import NaturalLanguage

protocol EmbeddingEngine {
    func embed(_ text: String) -> [Float]?
}

enum AppleSemanticEmbedding {
    static func makeEngine(language: NLLanguage = .english, allowDownload: Bool) async -> EmbeddingEngine? {
        if let contextual = await contextualEngine(language: language, allowDownload: allowDownload) {
            return contextual
        }
        guard NLEmbedding.sentenceEmbedding(for: language) != nil else { return nil }
        return SentenceEmbeddingEngine(language: language)
    }

    private static func contextualEngine(
        language: NLLanguage,
        allowDownload: Bool
    ) async -> ContextualEmbeddingEngine? {
        guard let model = NLContextualEmbedding(language: language) else { return nil }

        if !model.hasAvailableAssets {
            guard allowDownload else { return nil }
            guard await requestAssets(for: model) else { return nil }
        }

        guard (try? model.load()) != nil else { return nil }
        return ContextualEmbeddingEngine(model: model, language: language)
    }

    private static func requestAssets(for model: NLContextualEmbedding) async -> Bool {
        (try? await model.requestAssets()) == .available
    }
}

private final class ContextualEmbeddingEngine: EmbeddingEngine, @unchecked Sendable {
    private let model: NLContextualEmbedding
    private let language: NLLanguage

    init(model: NLContextualEmbedding, language: NLLanguage) {
        self.model = model
        self.language = language
    }

    func embed(_ text: String) -> [Float]? {
        guard !text.isEmpty, let result = try? model.embeddingResult(for: text, language: language) else {
            return nil
        }

        var sum = [Float](repeating: 0, count: model.dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for index in 0..<min(vector.count, sum.count) {
                sum[index] += Float(vector[index])
            }
            tokenCount += 1
            return true
        }

        guard tokenCount > 0 else { return nil }
        return normalized(sum.map { $0 / Float(tokenCount) })
    }
}

private struct SentenceEmbeddingEngine: EmbeddingEngine {
    let language: NLLanguage

    func embed(_ text: String) -> [Float]? {
        guard !text.isEmpty,
              let embedding = NLEmbedding.sentenceEmbedding(for: language),
              let vector = embedding.vector(for: text)
        else { return nil }

        return normalized(vector.map(Float.init))
    }
}

private func normalized(_ vector: [Float]) -> [Float]? {
    let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard magnitude > 0 else { return nil }
    return vector.map { $0 / magnitude }
}
