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
        guard model.isAvailable else { return nil }
        if let language = request.language, !model.supportsLocale(Locale(identifier: language)) {
            return nil
        }
        let excerpt = request.excerpt(characterBudget: Self.characterBudget)
        guard !excerpt.isEmpty else { return nil }

        let session = LanguageModelSession(
            model: model,
            instructions: MeetingTitlePrompt.instructions(language: request.language)
        )
        do {
            let response = try await session.respond(
                to: MeetingTitlePrompt.prompt(excerpt: excerpt, calendarTitle: request.calendarTitle),
                generating: GeneratedMeetingTitle.self
            )
            return TitleText.cleaned(response.content.title)
        } catch {
            return nil
        }
    }
}
