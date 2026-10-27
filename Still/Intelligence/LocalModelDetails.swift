import Foundation

protocol ModelTextGenerator: Sendable {
    func generate(system: String, user: String, schema: String, maximumTokens: Int) async throws -> String
}

extension LocalLanguageModel: ModelTextGenerator {}

struct LocalModelTitle<Model: ModelTextGenerator>: Sendable {
    static var maximumTokens: Int { 64 }
    static var characterBudget: Int { 6_000 }

    let model: Model

    func title(for request: TitleRequest) async -> String? {
        let excerpt = request.excerpt(characterBudget: Self.characterBudget)
        guard !excerpt.isEmpty else { return nil }
        guard let output = try? await model.generate(
            system: MeetingTitlePrompt.instructions(language: request.language),
            user: MeetingTitlePrompt.prompt(excerpt: excerpt, calendarTitle: request.calendarTitle),
            schema: Self.schema,
            maximumTokens: Self.maximumTokens
        ) else { return nil }
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return TitleText.cleaned(response.title)
    }

    static var schema: String { """
        {"type":"object","properties":{"title":{"type":"string","minLength":1,"maxLength":52}},\
        "required":["title"],"additionalProperties":false}
        """ }

    struct Response: Decodable {
        let title: String
    }
}

enum MeetingTitlePrompt {
    static func instructions(language: String?) -> String {
        let languageName = language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
        let writeIn = languageName.map { "Write the title in \($0)." } ?? "Write the title in the language of the transcript."
        return """
            You name recorded meetings. You read excerpts taken from the start, middle and end of a meeting \
            transcript and write one short, specific title of at most seven words in Title Case. \
            The title says what the meeting was about: its topic, project or main decision. \
            Never use greetings, small talk or filler words. Never invent names, dates or facts. \
            \(writeIn)
            """
    }

    static func prompt(excerpt: String, calendarTitle: String?) -> String {
        let hint = calendarTitle.map { "The calendar event for this meeting is called \"\($0)\".\n" } ?? ""
        return "\(hint)Transcript excerpts:\n\(excerpt)"
    }
}

enum TitleChain {
    static func first(
        of generators: [@MainActor @Sendable (TitleRequest) async -> String?],
        for request: TitleRequest
    ) async -> String? {
        for generate in generators {
            if let title = await generate(request).flatMap(TitleText.cleaned) {
                return title
            }
        }
        return nil
    }
}

struct LocalModelNoteGenerator<Model: ModelTextGenerator>: NoteGenerator, Sendable {
    static var maximumTokens: Int { 900 }

    let model: Model

    static var maximumPromptCharacters: Int { 2_400 }

    func note(template: NoteTemplate, segments: [TranscriptSegment], speakers: [Speaker]) async throws -> Note {
        let sentences = ExtractiveNoteGenerator.sentences(in: segments)
        guard !sentences.isEmpty else { return Note(template: template) }
        let language = segments.lazy.compactMap(\.language).first
        let byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let speaker: (_ sourceIDs: [UUID]) -> String? = { ids in
            ids.first.flatMap { byID[$0]?.speakerID }.flatMap { names[$0] }
        }
        var windows: [[(text: String, start: TimeInterval, sourceIDs: [UUID])]] = []
        var window: [(text: String, start: TimeInterval, sourceIDs: [UUID])] = []
        var characters = 0
        let fragments = sentences.flatMap { sentence -> [(text: String, start: TimeInterval, sourceIDs: [UUID])] in
            var pieces: [(text: String, start: TimeInterval, sourceIDs: [UUID])] = []
            var text = ""
            for word in sentence.text.split(whereSeparator: \.isWhitespace) {
                if !text.isEmpty, text.count + word.count + 1 > Self.maximumPromptCharacters - 16 {
                    pieces.append((text, sentence.start, sentence.sourceIDs))
                    text = ""
                }
                text += text.isEmpty ? String(word.prefix(Self.maximumPromptCharacters - 16)) : " " + String(word)
            }
            if !text.isEmpty { pieces.append((text, sentence.start, sentence.sourceIDs)) }
            return pieces
        }
        for sentence in fragments {
            let cost = sentence.text.count + (speaker(sentence.sourceIDs)?.count ?? 0) + 10
            if !window.isEmpty, characters + cost > Self.maximumPromptCharacters {
                windows.append(window)
                window = []
                characters = 0
            }
            window.append(sentence)
            characters += cost
        }
        if !window.isEmpty { windows.append(window) }

        var notes: [Note] = []
        var successes = 0
        var firstFailure: (any Error)?
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            do {
                let output = try await model.generate(
                    system: Self.instructions(language: language),
                    user: Self.numberedTranscript(window, speaker: speaker),
                    schema: Self.schema,
                    maximumTokens: Self.maximumTokens
                )
                let note = try Self.decode(output, template: template, sentences: window, language: language, speaker: speaker)
                notes.append(note)
                successes += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstFailure == nil { firstFailure = error }
                AITrace.record("note.windowFailed", ["window": "\(index + 1)/\(windows.count)", "error": String(describing: error)])
                let source = window.flatMap(\.sourceIDs).compactMap { byID[$0] }
                notes.append(try await ExtractiveNoteGenerator().note(template: template, segments: source))
            }
        }
        guard successes > 0, notes.contains(where: { !$0.generatedItems.isEmpty }) else { throw firstFailure ?? NoGroundedItems() }
        func combined(_ items: [NoteItem], limit: Int, preferred: Set<UUID> = []) -> [NoteItem] {
            var seen: Set<String> = []
            let ranked = items.enumerated().sorted { lhs, rhs in
                let left = ExtractiveNoteGenerator.importance(of: lhs.element.text) + (preferred.contains(lhs.element.id) ? 200 : 0)
                let right = ExtractiveNoteGenerator.importance(of: rhs.element.text) + (preferred.contains(rhs.element.id) ? 200 : 0)
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            return ranked.filter { seen.insert(MemoryText.normalized($0.element.text)).inserted }
                .prefix(limit).sorted { $0.offset < $1.offset }.map(\.element)
        }
        let modelSummaryIDs = Set(notes.filter { $0.generation?.source != .extractive }.flatMap(\.summary).map(\.id))
        return Note(
            template: template,
            summary: combined(notes.flatMap(\.summary), limit: 6, preferred: modelSummaryIDs),
            decisions: combined(notes.flatMap(\.decisions), limit: 8),
            actions: combined(notes.flatMap(\.actions), limit: 12),
            generation: NoteGeneration(source: firstFailure == nil ? .model : .mixed, problem: firstFailure.map { String(describing: $0) })
        )
    }

    private static func decode(
        _ output: String,
        template: NoteTemplate,
        sentences: [(text: String, start: TimeInterval, sourceIDs: [UUID])],
        language: String?,
        speaker: (_ sourceIDs: [UUID]) -> String?
    ) throws -> Note {
        let response = try JSONDecoder().decode(Response.self, from: Data(output.utf8))
        let byLine = Dictionary(uniqueKeysWithValues: sentences.enumerated().map { ($0.offset + 1, $0.element) })
        func items(_ entries: [Response.Entry], action: Bool = false) -> [NoteItem] {
            entries.compactMap { entry in
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let sources = entry.lines.compactMap { byLine[$0] }
                let ids = sources.flatMap(\.sourceIDs)
                let evidence = sources.map { [speaker($0.sourceIDs), $0.text].compactMap { $0 }.joined(separator: " ") }.joined(separator: " ")
                guard !text.isEmpty, !ids.isEmpty,
                      ProvenanceValidator().support(of: text, in: evidence) >= 0.6,
                      !action || (language != nil && language?.hasPrefix("en") == false) || sources.contains(where: { ExtractiveNoteGenerator.isAction($0.text) })
                else { return nil }
                return NoteItem(text: String(text.prefix(180)), sourceSegmentIDs: ids)
            }
        }
        let summary = items(response.summary)
        let decisions = items(response.decisions)
        let actions = items(response.actions, action: true)
        return Note(template: template, summary: summary, decisions: decisions, actions: actions)
    }

    static func numberedTranscript(
        _ sentences: [(text: String, start: TimeInterval, sourceIDs: [UUID])],
        speaker: (_ sourceIDs: [UUID]) -> String? = { _ in nil }
    ) -> String {
        sentences.enumerated().map { index, sentence in
            "[\(index + 1)] " + (speaker(sentence.sourceIDs).map { "\($0): " } ?? "") + sentence.text
        }
        .joined(separator: "\n")
    }

    static func instructions(language: String?) -> String {
        let languageName = language.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) } ?? "the transcript's language"
        return """
            Summarize this portion of a meeting using only supported facts.
            Each line starts with the speaker's name. Use it to understand who said, decided or committed to what. \
            Cite the lines of the person who decided or committed, because Still shows the speaker of every cited line.
            Return at most 2 concise summary items about substantive topics and outcomes, at most 2 explicit \
            decisions that participants accepted, and at most 3 concrete future actions somebody committed to do.
            Use clear concise wording with the transcript's key terms. Cite the supporting line numbers.
            Exclude greetings, small talk, questions and speculative proposals from outcomes and decisions.
            Availability, PTO, past work, capabilities and vague "do that" statements are not actions.
            Keep each item under 160 characters. Do not guess names, owners, dates or missing details.
            Write every item in \(languageName). Leave a list empty when nothing qualifies.
            """
    }

    static var itemSchema: String { """
        {"type":"object","properties":{"text":{"type":"string","minLength":1,"maxLength":160},\
        "lines":{"type":"array","minItems":1,"maxItems":6,"items":{"type":"integer","minimum":1}}},\
        "required":["text","lines"],"additionalProperties":false}
        """ }

    static var schema: String {
        """
        {"type":"object","properties":{"summary":{"type":"array","maxItems":2,"items":\(itemSchema)},\
        "decisions":{"type":"array","maxItems":2,"items":\(itemSchema)},\
        "actions":{"type":"array","maxItems":3,"items":\(itemSchema)}},\
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
