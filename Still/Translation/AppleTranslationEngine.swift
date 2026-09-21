import Foundation
import Translation

/// Wraps the system translator. The session comes from a view's
/// `translationTask`, which is also where the system asks the user to approve a
/// language-pack download. Still never downloads one on its own.
@MainActor
struct AppleTranslationEngine: TranslationEngine {
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func support(from source: Locale.Language, to target: Locale.Language) async -> TranslationSupport {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            .ready
        case .supported:
            .needsLanguagePack
        case .unsupported:
            .unsupported
        @unknown default:
            .unsupported
        }
    }

    func translate(
        _ texts: [String],
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws -> [String] {
        let requests = texts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }

        var byIndex: [Int: String] = [:]
        for try await response in session.translate(batch: requests) {
            guard let identifier = response.clientIdentifier, let index = Int(identifier) else { continue }
            byIndex[index] = response.targetText
        }

        guard byIndex.count == texts.count else { throw TranslationError.failed }
        return texts.indices.map { byIndex[$0] ?? "" }
    }
}
