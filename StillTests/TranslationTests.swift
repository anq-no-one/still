import Foundation
import Testing
@testable import Still

@MainActor
struct SegmentTranslatorTests {
    private let english = Locale.Language(identifier: "en")
    private let polish = Locale.Language(identifier: "pl")

    @Test
    func keepsTheOriginalBesideTheTranslation() async throws {
        let segments = words("We ship on Friday .")
        let engine = FakeTranslationEngine(support: .ready) { texts in texts.map { "PL:\($0)" } }

        let translated = try await SegmentTranslator(engine: engine).translate(segments, into: polish)

        #expect(translated.map(\.text) == segments.map(\.text))
        #expect(translated[0].translation == "PL:We ship on Friday .")
        #expect(translated[0].translationLanguage == "pl")
        #expect(translated[0].displayText == "We")
    }

    @Test
    func explainsAnUnsupportedPairAndChangesNothing() async {
        let segments = words("We ship on Friday .")
        let engine = FakeTranslationEngine(support: .unsupported) { $0 }

        await #expect(throws: TranslationError.unsupportedPair(source: "en", target: "pl")) {
            try await SegmentTranslator(engine: engine).translate(segments, into: polish)
        }
        #expect(segments.allSatisfy { $0.translation == nil })
    }

    @Test
    func asksForAPackInsteadOfDownloadingOne() async {
        let engine = FakeTranslationEngine(support: .needsLanguagePack) { $0 }

        await #expect(throws: TranslationError.packMissing) {
            try await SegmentTranslator(engine: engine).translate(words("Hello ."), into: polish)
        }
        #expect(engine.translateCalls == 0)
    }

    @Test
    func aFailedTranslationLeavesTheTranscriptAlone() async {
        let engine = FakeTranslationEngine(support: .ready) { _ in [] }

        await #expect(throws: TranslationError.failed) {
            try await SegmentTranslator(engine: engine).translate(words("Hello ."), into: polish)
        }
    }

    @Test
    func skipsTranslationWhenTheLanguagesMatch() async throws {
        let segments = words("Already english .")
        let engine = FakeTranslationEngine(support: .ready) { $0 }

        let result = try await SegmentTranslator(engine: engine).translate(segments, into: english)

        #expect(result == segments)
        #expect(engine.translateCalls == 0)
    }
}

@MainActor
final class FakeTranslationEngine: TranslationEngine {
    private let support: TranslationSupport
    private let transform: ([String]) -> [String]
    private(set) var translateCalls = 0

    init(support: TranslationSupport, transform: @escaping ([String]) -> [String]) {
        self.support = support
        self.transform = transform
    }

    func support(from source: Locale.Language, to target: Locale.Language) async -> TranslationSupport {
        support
    }

    func translate(_ texts: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        translateCalls += 1
        return transform(texts)
    }
}
