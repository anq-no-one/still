import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import Tokenizers

struct LocalModelExtractor: Extractor {
    static let maximumTokens = 900
    static let maximumItems = 6

    let id: String
    private let model: LocalLanguageModel

    init(pack: ModelPack, root: URL, model: LocalLanguageModel? = nil) {
        id = "\(pack.id)@\(pack.version)"
        self.model = model ?? LocalLanguageModel(directory: pack.installedDirectory(in: root))
    }

    static var canRun: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    func candidates(from segments: [ExtractionSegment], language: String?) async throws -> [ExtractionCandidate] {
        let sentences = TranscriptSentence.sentences(in: segments)
        guard !sentences.isEmpty else { return [] }

        let output = try await model.generate(
            system: Self.instructions(language: language),
            user: Self.numberedTranscript(sentences),
            schema: Self.schema,
            maximumTokens: Self.maximumTokens
        )
        return try Self.groundedCandidates(output, sentences: sentences, language: language)
    }

    static func groundedCandidates(_ output: String, sentences: [TranscriptSentence], language: String? = nil) throws -> [ExtractionCandidate] {
        let response = try JSONDecoder().decode(Response.self, from: Data(output.utf8))
        return response.items.compactMap { item in
            let source = item.lines.filter { sentences.indices.contains($0 - 1) }.map { sentences[$0 - 1] }
            let cited = source.flatMap(\.segmentIDs)
            guard var kind = MemoryKind(rawValue: item.kind), !cited.isEmpty else { return nil }
            if kind == .task, language == nil || language?.lowercased().hasPrefix("en") == true, !source.contains(where: { ExtractiveNoteGenerator.isAction($0.text) }) {
                guard source.contains(where: { ExtractiveNoteGenerator.isAvailability($0.text) }) else { return nil }
                kind = .fact
            }

            return ExtractionCandidate(
                kind: kind,
                text: item.text,
                citedSegmentIDs: cited,
                owner: kind == .task && !item.owner.isEmpty ? item.owner : nil,
                due: kind == .task && !item.due.isEmpty ? item.due : nil
            )
        }
    }

    static func numberedTranscript(_ sentences: [TranscriptSentence]) -> String {
        sentences.enumerated().map { index, sentence in
            let speaker = sentence.speaker.map { "\($0): " } ?? ""
            return "[\(index + 1)] \(speaker)\(sentence.text)"
        }
        .joined(separator: "\n")
    }

    static func instructions(language: String?) -> String {
        let languageName = language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) } ?? "the transcript's language"
        return """
        You read a numbered meeting transcript and list what it states explicitly.
        A decision is something the participants agreed or settled.
        A fact is a concrete statement about the project: a date, number, status, constraint or name.
        A task is a specific future action a person explicitly committed to do; give the owner and due date only when the transcript says them, otherwise an empty string.
        PTO, availability, completed work, capabilities and questions are not tasks.
        Cite every line number that supports an item. Use concise faithful paraphrases. Never add anything the transcript does not say.
        Write the text in \(languageName). Return at most \(maximumItems) items, or an empty list when nothing qualifies.
        """
    }

    static let schema = """
    {"type":"object","properties":{"items":{"type":"array","maxItems":\(maximumItems),"items":{"type":"object","properties":{\
    "kind":{"type":"string","enum":["decision","fact","task"]},\
    "text":{"type":"string","minLength":1,"maxLength":160},\
    "lines":{"type":"array","minItems":1,"maxItems":6,"items":{"type":"integer","minimum":1}},\
    "owner":{"type":"string","maxLength":80},\
    "due":{"type":"string","maxLength":80}},\
    "required":["kind","text","lines","owner","due"],"additionalProperties":false}}},\
    "required":["items"],"additionalProperties":false}
    """

    struct Response: Decodable {
        struct Item: Decodable {
            let kind: String
            let text: String
            let lines: [Int]
            let owner: String
            let due: String
        }

        let items: [Item]
    }
}

actor LocalLanguageModel {
    private static let execution = ModelExecutionQueue(
        prepare: {
            Memory.cacheLimit = 0
            Memory.clearCache()
        },
        cleanup: { Memory.clearCache() }
    )
    private let directory: URL
    private var container: ModelContainer?

    init(directory: URL) {
        self.directory = directory
    }

    func generate(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String {
        try await Self.execution.perform {
            try await self.generateExclusively(system: system, user: user, schema: schema, maximumTokens: maximumTokens)
        }
    }

    private func generateExclusively(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String {
        let span = Perf.begin("mlx.generate")
        let model = directory.lastPathComponent
        do {
            let (output, tokens) = try await generateCounting(system: system, user: user, schema: schema, maximumTokens: maximumTokens)
            let ms = Perf.end(span, [
                "recordingID": AITrace.recordingID?.uuidString ?? "-",
                "stage": AITrace.stage ?? "-",
                "model": model,
                "promptChars": String(system.count + user.count),
                "tokens": String(tokens),
                "tokensPerSecond": String(format: "%.1f", Double(tokens) / max(span.elapsedMS / 1000, 0.001)),
            ])
            AITrace.record("mlx.generate", ms: ms, [
                "model": model,
                "system": system,
                "user": user,
                "schema": schema,
                "maximumTokens": String(maximumTokens),
                "output": output,
                "tokens": String(tokens),
            ])
            return output
        } catch {
            let ms = Perf.end(span, ["stage": AITrace.stage ?? "-", "model": model, "error": String(describing: error)])
            AITrace.record("mlx.generate.failed", ms: ms, ["model": model, "system": system, "user": user, "schema": schema, "maximumTokens": String(maximumTokens), "error": String(describing: error)])
            throw error
        }
    }

    private func generateCounting(system: String, user: String, schema: String, maximumTokens: Int) async throws -> (String, Int) {
        let container = try await loaded()
        return try await container.perform { context in
            let tokenizer = context.tokenizer
            let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: vocabulary.vocab,
                vocabType: vocabulary.vocabType,
                eosTokenId: Int32(tokenizer.eosTokenId ?? 0)
            )
            let constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer,
                jsonSchema: schema,
                fastForward: true,
                hostTokenizer: tokenizer
            )
            let input = try await context.processor.prepare(
                input: UserInput(
                    chat: [.system(system), .user(user)],
                    additionalContext: ["enable_thinking": false]
                )
            )

            var output = ""
            var tokens = 0
            do {
                try GuidedGenerationLoop.run(
                    input: input,
                    context: context,
                    constraint: constraint,
                    maxTokens: maximumTokens,
                    vocabSize: grammarTokenizer.vocabSize
                ) { delta in
                    output += delta
                    tokens += 1
                    return !Task.isCancelled
                }
            } catch {
                AITrace.record("mlx.generate.partial", [
                    "model": self.directory.lastPathComponent,
                    "output": output,
                    "tokens": String(tokens),
                    "maximumTokens": String(maximumTokens),
                    "schema": schema,
                    "error": String(describing: error),
                ])
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            return (output, tokens)
        }
    }

    private func loaded() async throws -> ModelContainer {
        if let container { return container }

        let footprintBefore = ResourceSampler.footprintBytes()
        let loaded = try await Perf.trace("mlx.load", ["model": directory.lastPathComponent]) {
            try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        }
        DevLog.event("mlx.loaded", [
            "model": directory.lastPathComponent,
            "footprintDeltaMB": String(format: "%.0f", (Double(ResourceSampler.footprintBytes()) - Double(footprintBefore)) / 1_048_576),
        ])
        MLXMemoryProbe.register()
        container = loaded
        return loaded
    }
}

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
