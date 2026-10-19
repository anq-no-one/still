import Foundation
import FoundationModels

@Generable
struct GeneratedMeetingTitle {
    @Guide(description: "A specific meeting title of at most seven words in Title Case")
    let title: String
}

struct FoundationModelTitle: Sendable {
    static let characterBudget = 4_000

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    func title(for request: TitleRequest) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            AITrace.record("apple.title.skipped", ["reason": "unavailable \(model.availability)"])
            return nil
        }
        if let language = request.language, !model.supportsLocale(Locale(identifier: language)) {
            AITrace.record("apple.title.skipped", ["reason": "unsupported language \(language)"])
            return nil
        }
        let excerpt = request.excerpt(characterBudget: Self.characterBudget)
        guard !excerpt.isEmpty else { return nil }

        let session = LanguageModelSession(
            model: model,
            instructions: MeetingTitlePrompt.instructions(language: request.language)
        )
        let prompt = MeetingTitlePrompt.prompt(excerpt: excerpt, calendarTitle: request.calendarTitle)
        let span = Perf.begin("apple.title")
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedMeetingTitle.self)
            let ms = Perf.end(span, ["recordingID": AITrace.recordingID?.uuidString ?? "-"])
            AITrace.record("apple.title", ms: ms, [
                "system": MeetingTitlePrompt.instructions(language: request.language),
                "user": prompt,
                "output": response.content.title,
            ])
            return TitleText.cleaned(response.content.title)
        } catch {
            let ms = Perf.end(span, ["error": String(describing: error)])
            AITrace.record("apple.title.failed", ms: ms, ["user": prompt, "error": String(describing: error)])
            return nil
        }
    }
}
