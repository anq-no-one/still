import AppIntents
import Foundation

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a recording"
    static let description = IntentDescription("Starts recording on this device. Nothing is uploaded.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let coordinator = StillIntentEnvironment.shared.coordinator else {
            throw StillIntentError.unavailable
        }

        _ = try StillIntentEnvironment.shared.unlockedLibrary()
        await coordinator.start()
        return .result()
    }
}

struct SearchLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search my recordings"
    static let description = IntentDescription("Finds words in your recordings. The search stays on this device.")

    @Parameter(title: "Words")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let library = try StillIntentEnvironment.shared.unlockedLibrary()
        let results = LibrarySearch.results(for: query, in: library.recordings)
        guard !results.isEmpty else { throw StillIntentError.noRecordings }

        return .result(value: results.prefix(10).map(\.snippet))
    }
}

struct OpenRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a recording"
    static let description = IntentDescription("Opens a recording in Still.")
    static let openAppWhenRun = true

    @Parameter(title: "Title")
    var title: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let library = try StillIntentEnvironment.shared.unlockedLibrary()
        guard let match = library.recordings.first(where: {
            $0.title.localizedCaseInsensitiveContains(title)
        }) else { throw StillIntentError.noRecordings }

        return .result(value: match.title)
    }
}

struct SummarizeRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize a recording"
    static let description = IntentDescription("Reads back the notes Still already made from a recording.")

    @Parameter(title: "Title")
    var title: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let library = try StillIntentEnvironment.shared.unlockedLibrary()
        guard let match = library.recordings.first(where: {
            $0.title.localizedCaseInsensitiveContains(title)
        }), let note = match.note else { throw StillIntentError.noRecordings }

        let lines = note.summary.map(\.text) + note.decisions.map(\.text) + note.actions.map(\.text)
        guard !lines.isEmpty else { throw StillIntentError.noRecordings }

        return .result(value: lines.joined(separator: "\n"))
    }
}

struct StillShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start a recording with \(.applicationName)", "Record with \(.applicationName)"],
            shortTitle: "Start a recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: SearchLibraryIntent(),
            phrases: ["Search \(.applicationName)", "Find in \(.applicationName)"],
            shortTitle: "Search recordings",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenRecordingIntent(),
            phrases: ["Open a recording in \(.applicationName)"],
            shortTitle: "Open a recording",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SummarizeRecordingIntent(),
            phrases: ["Summarize a recording in \(.applicationName)"],
            shortTitle: "Summarize a recording",
            systemImageName: "text.append"
        )
    }
}
