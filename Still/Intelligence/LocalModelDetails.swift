import Foundation

protocol ModelTextGenerator: Sendable {
    func generate(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String
}

extension LocalLanguageModel: ModelTextGenerator {}

struct LocalModelTitle<Model: ModelTextGenerator>: Sendable {
    static var maximumTokens: Int { 64 }
    static var maximumLength: Int { 52 }

    let model: Model

    func title(for segments: [TranscriptSegment]) async -> String? {
        let sentences = ExtractiveNoteGenerator.sentences(in: segments)
        let transcript = sentences.map(\.text).joined(separator: " ")
        guard !transcript.isEmpty else { return nil }
        guard let output = try? await model.generate(
            system: Self.instructions,
            user: String(transcript.prefix(2_000)),
            schema: Self.schema,
            maximumTokens: Self.maximumTokens
        ) else { return nil }
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        let title = response.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= Self.maximumLength else { return nil }
        return title
    }

    static var instructions: String { """
        Read the meeting transcript and write a short title for it, at most seven words.
        Use the transcript's own words. Never invent names, dates or facts.
        """ }

    static var schema: String { """
        {"type":"object","properties":{"title":{"type":"string","minLength":1,"maxLength":52}},\
        "required":["title"],"additionalProperties":false}
        """ }

    struct Response: Decodable {
        let title: String
    }
}

struct LocalModelNoteGenerator<Model: ModelTextGenerator>: NoteGenerator, Sendable {
    static var maximumTokens: Int { 900 }

    let model: Model

    func note(template: NoteTemplate, segments: [TranscriptSegment]) async throws -> Note {
        let sentences = ExtractiveNoteGenerator.sentences(in: segments)
        guard !sentences.isEmpty else { return Note(template: template) }
        let language = segments.lazy.compactMap(\.language).first
        let output = try await model.generate(
            system: Self.instructions(language: language),
            user: Self.numberedTranscript(sentences),
            schema: Self.schema,
            maximumTokens: Self.maximumTokens
        )
        let response = try JSONDecoder().decode(Response.self, from: Data(output.utf8))
        let byLine = Dictionary(uniqueKeysWithValues: sentences.enumerated().map { ($0.offset + 1, $0.element) })
        func items(_ entries: [Response.Entry]) -> [NoteItem] {
            entries.compactMap { entry in
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let ids = entry.lines.compactMap { byLine[$0]?.sourceIDs }.flatMap { $0 }
                guard !text.isEmpty, !ids.isEmpty else { return nil }
                return NoteItem(text: String(text.prefix(280)), sourceSegmentIDs: ids)
            }
        }
        let summary = items(response.summary)
        let decisions = items(response.decisions)
        let actions = items(response.actions)
        guard !summary.isEmpty || !decisions.isEmpty || !actions.isEmpty else { throw NoGroundedItems() }
        return Note(template: template, summary: summary, decisions: decisions, actions: actions)
    }

    static func numberedTranscript(_ sentences: [(text: String, start: TimeInterval, sourceIDs: [UUID])]) -> String {
        sentences.enumerated().map { index, sentence in "[\(index + 1)] \(sentence.text)" }
            .joined(separator: "\n")
    }

    static func instructions(language: String?) -> String {
        let languageName = language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) } ?? "the transcript's language"
        return """
            Read the numbered transcript and quote what it states explicitly.
            The summary holds the most important statements, decisions hold what was agreed or settled, \
            actions hold what someone committed to do.
            Quote the transcript's own words and cite every line number that supports an item.
            Write every item in \(languageName). Leave a list empty when nothing qualifies.
            """
    }

    static var itemSchema: String { """
        {"type":"object","properties":{"text":{"type":"string","minLength":1,"maxLength":280},\
        "lines":{"type":"array","minItems":1,"maxItems":6,"items":{"type":"integer","minimum":1}}},\
        "required":["text","lines"],"additionalProperties":false}
        """ }

    static var schema: String {
        """
        {"type":"object","properties":{"summary":{"type":"array","items":\(itemSchema)},\
        "decisions":{"type":"array","items":\(itemSchema)},\
        "actions":{"type":"array","items":\(itemSchema)}},\
        "required":["summary","decisions","actions"],"additionalProperties":false}
        """
    }

    struct Response: Decodable {
        struct Entry: Decodable {
            let text: String
            let lines: [Int]
        }

        let summary: [Entry]
        let decisions: [Entry]
        let actions: [Entry]
    }

    struct NoGroundedItems: Error {}
}
