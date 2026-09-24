import Foundation
import SwiftData
import Testing
@testable import Still

struct ProjectHistoryTests {
    private let project = UUID()
    private let september1 = Date(timeIntervalSince1970: 1_788_220_800)
    private var september10: Date { september1.addingTimeInterval(9 * 86_400) }

    @Test
    func aLaterDecisionBecomesCurrentAndKeepsTheEarlierOneWithItsSource() throws {
        let first = recording("We decided to ship the beta on Friday .", on: september1)
        let second = recording("Okay , ship the beta on Monday instead .", on: september10)

        let history = ProjectHistory(recordings: [first, second], project: project)

        let thread = try #require(history.threads.first)
        #expect(history.threads.count == 1)
        #expect(thread.current.item.text == "Okay , ship the beta on Monday instead .")
        #expect(thread.current.recordingID == second.id)
        #expect(thread.hasChanged)
        let earlier = try #require(thread.earlier.first)
        #expect(earlier.item.text == "We decided to ship the beta on Friday .")
        #expect(earlier.recordingID == first.id)
        #expect(earlier.recordingDate == september1)
        #expect(earlier.time == 0)
        #expect(history.superseded.map(\.recordingID) == [first.id])
    }

    @Test
    func decisionsAboutDifferentSubjectsStayApart() {
        let first = recording("We decided to ship the beta on Friday .", on: september1)
        let second = recording("We agreed to use Postgres for storage .", on: september10)

        let history = ProjectHistory(recordings: [first, second], project: project)

        #expect(history.threads.count == 2)
        #expect(history.current.map(\.recordingID) == [second.id, first.id])
        #expect(history.superseded.isEmpty)
    }

    @Test
    func repeatingADecisionIsNotAChange() throws {
        let first = recording("We decided to ship the beta on Friday .", on: september1)
        let second = recording("We decided to ship the beta on Friday .", on: september10)

        let thread = try #require(ProjectHistory(recordings: [first, second], project: project).threads.first)

        #expect(thread.current.recordingID == second.id)
        #expect(thread.earlier.map(\.recordingID) == [first.id])
        #expect(!thread.hasChanged)
    }

    @Test
    func aRejectedDecisionDoesNotReplaceTheCurrentOne() throws {
        let first = recording("We decided to ship the beta on Friday .", on: september1)
        var second = recording("Okay , ship the beta on Monday instead .", on: september10)
        second.memory = second.memory.map { memory in
            memory.updating(memory.items[0].id) { $0.reviewed(.declined) }
        }

        let thread = try #require(ProjectHistory(recordings: [first, second], project: project).threads.first)

        #expect(thread.current.recordingID == first.id)
        #expect(thread.earlier.isEmpty)
    }

    @Test
    func aConfirmedDecisionWinsATieWithAnExtractedOne() throws {
        let segments = words("We decided to ship the beta Friday or Monday")
        let friday = MemoryItem(kind: .decision, text: "ship the beta Friday", sourceSegmentIDs: segments.map(\.id), sourceStart: 0)
        let monday = MemoryItem(kind: .decision, text: "ship the beta Monday", sourceSegmentIDs: segments.map(\.id), sourceStart: 0)

        for winner in [friday, monday] {
            let memory = RecordingMemory(items: [friday, monday]).updating(winner.id) { $0.reviewed(.approved) }
            let meeting = recording(segments: segments, memory: memory, on: september1)

            let thread = try #require(ProjectHistory(recordings: [meeting], project: project).threads.first)

            #expect(thread.current.item.id == winner.id)
        }
    }

    @Test
    func aDeletedRecordingTakesItsDecisionOutOfTheHistory() throws {
        let first = recording("We decided to ship the beta on Friday .", on: september1)
        var second = recording("Okay , ship the beta on Monday instead .", on: september10)
        second.deletedAt = september10

        let thread = try #require(ProjectHistory(recordings: [first, second], project: project).threads.first)

        #expect(thread.current.recordingID == first.id)
        #expect(thread.earlier.isEmpty)
    }

    @Test
    func aCorrectionThatNoLongerSupportsADecisionDropsIt() throws {
        let first = recording("We decided to ship the beta on Friday .", on: september1)
        var second = recording("Ship the beta on Monday .", on: september10)
        second.segments[2].correction = "demo"
        second.segments[4].correction = "Tuesday"

        let thread = try #require(ProjectHistory(recordings: [first, second], project: project).threads.first)

        #expect(thread.current.recordingID == first.id)
        #expect(!thread.hasChanged)
    }

    @Test
    func aDecisionWhoseCitedSegmentIsGoneIsDropped() {
        var meeting = recording("We decided to ship the beta on Friday .", on: september1)
        meeting.segments.removeLast()

        #expect(ProjectHistory(recordings: [meeting], project: project).threads.isEmpty)
    }

    @Test
    func anEditedDecisionStaysWhileItsSourceExists() throws {
        var meeting = recording("We decided to ship the beta on Friday .", on: september1)
        meeting.memory = meeting.memory.map { memory in
            memory.updating(memory.items[0].id) { $0.edited(to: "Ship the beta after legal review") }
        }

        let thread = try #require(ProjectHistory(recordings: [meeting], project: project).threads.first)

        #expect(thread.current.item.text == "Ship the beta after legal review")
    }

    @Test
    func anotherProjectOrAnUnconfirmedRecordingDoesNotCount() {
        var elsewhere = recording("Okay , ship the beta on Monday instead .", on: september10)
        elsewhere.assign(toProject: UUID())
        var unconfirmed = recording("Okay , ship the beta on Tuesday instead .", on: september10)
        unconfirmed.projectAssignedAt = nil
        let first = recording("We decided to ship the beta on Friday .", on: september1)

        let history = ProjectHistory(recordings: [first, elsewhere, unconfirmed], project: project)

        #expect(history.current.map(\.recordingID) == [first.id])
        #expect(history.superseded.isEmpty)
    }

    private func recording(_ text: String, on date: Date) -> Recording {
        let segments = words(text)
        let item = MemoryItem(kind: .decision, text: text, sourceSegmentIDs: segments.map(\.id), sourceStart: 0)
        return recording(segments: segments, memory: RecordingMemory(items: [item]), on: date)
    }

    private func recording(segments: [TranscriptSegment], memory: RecordingMemory, on date: Date) -> Recording {
        var recording = Recording(
            title: "Planning",
            transcript: segments.plainText,
            segments: segments,
            createdAt: date,
            duration: 60,
            projectID: project,
            memory: memory
        )
        recording.assign(toProject: project, at: date)
        return recording
    }
}

struct DashboardTests {
    private let project = UUID()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test
    func recordingsAwaitingAProjectComeNewestFirst() {
        let older = Recording(title: "Older", transcript: "", createdAt: now.addingTimeInterval(-7_200), duration: 60)
        let newer = Recording(title: "Newer", transcript: "", createdAt: now.addingTimeInterval(-3_600), duration: 60)
        let filed = decided("We decided to ship the beta on Friday .", daysAgo: 1)

        let dashboard = Dashboard(recordings: [older, filed, newer], now: now)

        #expect(dashboard.awaitingProject.map(\.id) == [newer.id, older.id])
    }

    @Test
    func onlyProposedTasksFromFiledRecordingsAwaitReview() throws {
        let segments = words("I will send the release notes . I will book the room .")
        let send = MemoryItem(kind: .task, text: "I will send the release notes", sourceSegmentIDs: segments[0...5].map(\.id), sourceStart: 0)
        let book = MemoryItem(kind: .task, text: "I will book the room", sourceSegmentIDs: segments[7...11].map(\.id), sourceStart: 7)
        var filed = Recording(
            title: "Launch",
            transcript: segments.plainText,
            segments: segments,
            createdAt: now,
            duration: 60,
            projectID: project,
            memory: RecordingMemory(items: [send, book]).updating(book.id) { $0.reviewed(.approved) }
        )
        filed.assign(toProject: project, at: now)
        let unfiled = Recording(title: "Loose", transcript: filed.transcript, segments: segments, createdAt: now, duration: 60, memory: filed.memory)

        let dashboard = Dashboard(recordings: [filed, unfiled], now: now)

        let task = try #require(dashboard.proposedTasks.first)
        #expect(dashboard.proposedTasks.count == 1)
        #expect(task.item.id == send.id)
        #expect(task.recordingID == filed.id)
        #expect(task.time == 0)
    }

    @Test
    func aTaskWhoseSourceWasCorrectedAwayLeavesTheDashboard() {
        let segments = words("I will send the release notes .")
        var corrected = segments
        corrected[2].correction = "skip"
        corrected[4].correction = "slides"
        let send = MemoryItem(kind: .task, text: "I will send the release notes", sourceSegmentIDs: segments[0...5].map(\.id), sourceStart: 0)
        var recording = Recording(
            title: "Launch",
            transcript: segments.plainText,
            segments: corrected,
            createdAt: now,
            duration: 60,
            projectID: project,
            memory: RecordingMemory(items: [send])
        )
        recording.assign(toProject: project, at: now)

        #expect(Dashboard(recordings: [recording], now: now).proposedTasks.isEmpty)
    }

    @Test
    func recentlyChangedDecisionsOpenAtTheirNewSource() throws {
        let friday = decided("We decided to ship the beta on Friday .", daysAgo: 20)
        let monday = decided("Okay , ship the beta on Monday instead .", daysAgo: 2)
        let oldStorage = decided("We agreed to use Postgres for storage .", daysAgo: 40)
        let newStorage = decided("We agreed to use SQLite for storage .", daysAgo: 30)

        let dashboard = Dashboard(recordings: [friday, monday, oldStorage, newStorage], now: now)

        let change = try #require(dashboard.changedDecisions.first)
        #expect(dashboard.changedDecisions.count == 1)
        #expect(change.current.recordingID == monday.id)
        #expect(change.earlier.map(\.recordingID) == [friday.id])
        #expect(!dashboard.isEmpty)
    }

    @Test
    func aLibraryWithNothingToResolveHasAnEmptyDashboard() {
        let settled = decided("We decided to ship the beta on Friday .", daysAgo: 1)

        #expect(Dashboard(recordings: [settled], now: now).isEmpty)
    }

    private func decided(_ text: String, daysAgo days: Double) -> Recording {
        let date = now.addingTimeInterval(-days * 86_400)
        let segments = words(text)
        let item = MemoryItem(kind: .decision, text: text, sourceSegmentIDs: segments.map(\.id), sourceStart: 0)
        var recording = Recording(
            title: "Planning",
            transcript: segments.plainText,
            segments: segments,
            createdAt: date,
            duration: 60,
            projectID: project,
            memory: RecordingMemory(items: [item])
        )
        recording.assign(toProject: project, at: date)
        return recording
    }
}

@MainActor
struct DerivedProjectViewTests {
    private let project = UUID()

    @Test
    func deletingOrCorrectingASourceUpdatesTheLibraryHistory() async throws {
        let library = try await makeLibrary()
        let first = decided("We decided to ship the beta on Friday .", on: .now.addingTimeInterval(-86_400))
        let second = decided("Ship the beta on Monday .", on: .now)
        try library.add(first)
        try library.add(second)
        #expect(library.projectHistory(project).current.map(\.recordingID) == [second.id])
        #expect(library.dashboard().changedDecisions.map(\.current.recordingID) == [second.id])

        var corrected = try #require(library.recordings.first { $0.id == second.id })
        corrected.segments[2].correction = "demo"
        corrected.segments[4].correction = "Tuesday"
        try library.save(corrected)
        #expect(library.projectHistory(project).current.map(\.recordingID) == [first.id])
        #expect(library.dashboard().changedDecisions.isEmpty)

        try library.delete(first)
        #expect(library.projectHistory(project).threads.isEmpty)
    }

    @Test
    func openingASourceSelectsTheRecordingAtItsTime() {
        let navigation = LibraryNavigation()
        let recording = UUID()

        navigation.open(recording, at: 42)
        #expect(navigation.selection == recording)
        #expect(navigation.startTime == 42)

        navigation.selection = UUID()
        #expect(navigation.startTime == nil)

        navigation.open(recording, at: nil)
        #expect(navigation.selection == recording)
        #expect(navigation.startTime == nil)
    }

    private func decided(_ text: String, on date: Date) -> Recording {
        let segments = words(text)
        let item = MemoryItem(kind: .decision, text: text, sourceSegmentIDs: segments.map(\.id), sourceStart: 0)
        var recording = Recording(
            title: "Planning",
            transcript: segments.plainText,
            segments: segments,
            createdAt: date,
            duration: 60,
            projectID: project,
            memory: RecordingMemory(items: [item])
        )
        recording.assign(toProject: project, at: date)
        return recording
    }

    private func makeLibrary() async throws -> Library {
        let context = try ModelContext(
            ModelContainer(
                for: EncryptedRecording.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            )
        )
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: try Scratch().directory,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        return library
    }
}
