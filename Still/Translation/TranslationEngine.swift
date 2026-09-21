import Foundation

enum TranslationSupport: Equatable, Sendable {
    case ready
    case needsLanguagePack
    case unsupported
}

@MainActor
protocol TranslationEngine {
    func support(from source: Locale.Language, to target: Locale.Language) async -> TranslationSupport
    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String]
}

enum TranslationError: LocalizedError, Equatable {
    case unsupportedPair(source: String, target: String)
    case packMissing
    case failed

    var errorDescription: String? {
        switch self {
        case .unsupportedPair(let source, let target):
            return "Still cannot translate \(source) into \(target) on this device. The original transcript is unchanged."
        case .packMissing:
            return "Still needs a language pack before it can translate offline. The original transcript is unchanged."
        case .failed:
            return "Translation did not finish. The original transcript is unchanged."
        }
    }
}

/// Translations live beside the transcript. The original stays the record of
/// what was said, and a failure leaves it exactly as it was.
@MainActor
struct SegmentTranslator {
    let engine: TranslationEngine

    func translate(
        _ segments: [TranscriptSegment],
        into target: Locale.Language
    ) async throws -> [TranscriptSegment] {
        guard let source = spokenLanguage(of: segments) else { throw TranslationError.failed }
        guard source.languageCode != target.languageCode else { return segments }

        switch await engine.support(from: source, to: target) {
        case .unsupported:
            throw TranslationError.unsupportedPair(
                source: source.languageCode?.identifier ?? "?",
                target: target.languageCode?.identifier ?? "?"
            )
        case .needsLanguagePack:
            throw TranslationError.packMissing
        case .ready:
            break
        }

        let sentences = ExtractiveNoteGenerator.sentences(in: segments)
        let translated = try await engine.translate(sentences.map(\.text), from: source, to: target)
        guard translated.count == sentences.count else { throw TranslationError.failed }

        var byID: [UUID: String] = [:]
        for (sentence, text) in zip(sentences, translated) {
            guard let first = sentence.sourceIDs.first else { continue }
            byID[first] = text
        }

        return segments.map { segment in
            guard let text = byID[segment.id] else { return segment }

            var copy = segment
            copy.translation = text
            copy.translationLanguage = target.languageCode?.identifier
            return copy
        }
    }

    private func spokenLanguage(of segments: [TranscriptSegment]) -> Locale.Language? {
        segments.compactMap(\.language).first.map { Locale.Language(identifier: $0) }
    }
}
