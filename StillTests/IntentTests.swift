import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct StillIntentEnvironmentTests {
    @Test
    func aLockedLibraryAsksForAuthenticationInsteadOfAnswering() async throws {
        let library = try makeLockedLibrary()
        StillIntentEnvironment.shared.install(library: library, coordinator: makeCoordinator(library: library))

        #expect(throws: StillIntentError.locked) {
            try StillIntentEnvironment.shared.unlockedLibrary()
        }
    }

    @Test
    func anUnlockedLibraryAnswers() async throws {
        let library = try makeLockedLibrary()
        await library.unlock()
        StillIntentEnvironment.shared.install(library: library, coordinator: makeCoordinator(library: library))

        #expect(try StillIntentEnvironment.shared.unlockedLibrary() === library)
    }

    private func makeCoordinator(library: Library) -> RecordingCoordinator {
        RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { FakeTranscriptionSession() },
            makeFinalTranscription: { FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600) }
        )
    }

    private func makeLockedLibrary() throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        return Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: try Scratch().directory,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } },
            makeEmbeddingEngine: { nil }
        )
        )
    }
}

@MainActor
struct CalendarContextTests {
    private let meeting = MeetingContext(title: "Board sync", participants: ["Anna", "Ben"])

    @Test
    func suggestsNothingWithoutCalendarAccess() async {
        let source = FakeCalendarSource(hasAccess: false, events: [meeting])

        let suggestion = await CalendarContext(source: source).suggestion(at: .now)

        #expect(suggestion == nil)
        #expect(source.reads == 0)
    }

    @Test
    func suggestsTheEventTitleAndPeople() async {
        let source = FakeCalendarSource(hasAccess: true, events: [meeting])

        let suggestion = await CalendarContext(source: source).suggestion(at: .now)

        #expect(suggestion == meeting)
    }

    @Test
    func suggestsNothingWhenTheCalendarIsEmpty() async {
        let source = FakeCalendarSource(hasAccess: true, events: [])

        #expect(await CalendarContext(source: source).suggestion(at: .now) == nil)
    }
}

@MainActor
final class FakeCalendarSource: CalendarSource {
    private let access: Bool
    private let events: [MeetingContext]
    private(set) var reads = 0

    init(hasAccess: Bool, events: [MeetingContext]) {
        access = hasAccess
        self.events = events
    }

    func hasAccess() async -> Bool { access }
    func requestAccess() async -> Bool { access }

    func events(around date: Date) async -> [MeetingContext] {
        reads += 1
        return events
    }
}
