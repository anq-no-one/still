import Foundation
import SwiftData
import Testing
@testable import Still

struct ProvenanceTests {
    private let segments = words("We agreed to ship the beta on Friday . Anna will send the release notes .")
    private let validator = ProvenanceValidator()

    @Test
    func aSupportedItemKeepsItsSegmentsAndAudioTime() throws {
        let cited = Array(segments[9...15])
        let outcome = validator.validate(
            [ExtractionCandidate(kind: .task, text: "Anna sends the release notes", citedSegmentIDs: cited.map(\.id).reversed())],
            against: segments
        )

        let item = try #require(outcome.items.first)
        #expect(outcome.withheld == 0)
        #expect(item.sourceSegmentIDs == cited.map(\.id))
        #expect(item.sourceStart == 9)
        #expect(item.status == .proposed)
    }

    @Test
    func aCitationOfAMissingSegmentIsWithheld() {
        let outcome = validator.validate(
            [ExtractionCandidate(kind: .fact, text: "The beta ships on Friday", citedSegmentIDs: [segments[0].id, UUID()])],
            against: segments
        )

        #expect(outcome.items.isEmpty)
        #expect(outcome.withheld == 1)
    }

    @Test
    func anItemWithoutCitationsIsWithheld() {
        let outcome = validator.validate(
            [ExtractionCandidate(kind: .decision, text: "Ship the beta", citedSegmentIDs: [])],
            against: segments
        )

        #expect(outcome.items.isEmpty)
        #expect(outcome.withheld == 1)
    }

    @Test
    func textTheCitedSegmentsDoNotSupportIsWithheld() {
        let outcome = validator.validate(
            [
                ExtractionCandidate(kind: .decision, text: "The budget doubled for marketing", citedSegmentIDs: segments[0...7].map(\.id)),
                ExtractionCandidate(kind: .decision, text: "Ship the beta on Friday", citedSegmentIDs: segments[0...7].map(\.id)),
            ],
            against: segments
        )

        #expect(outcome.items.map(\.text) == ["Ship the beta on Friday"])
        #expect(outcome.withheld == 1)
    }

    @Test
    func anOwnerOrDueDateTheTranscriptDoesNotMentionIsDropped() {
        let outcome = validator.validate(
            [ExtractionCandidate(kind: .task, text: "Send the release notes", citedSegmentIDs: segments[9...15].map(\.id), owner: "Boris", due: "Monday")],
            against: segments
        )

        #expect(outcome.items.first?.owner == nil)
        #expect(outcome.items.first?.due == nil)
    }
}

struct MemoryItemTests {
    private let segment = UUID()

    @Test
    func factsStayAutomaticallyExtractedUntilTheUserConfirms() {
        let fact = MemoryItem(kind: .fact, text: "The beta ships on Friday", sourceSegmentIDs: [segment], sourceStart: 3)

        #expect(fact.status == .extracted)
        #expect(fact.isAutomaticallyExtracted)
        #expect(fact.reviewed(.approved).status == .confirmed)
        #expect(!fact.reviewed(.approved).isAutomaticallyExtracted)
        #expect(fact.reviewed(.declined).status == .rejected)
    }

    @Test
    func tasksAreProposedUntilAcceptedOrDismissed() {
        let task = MemoryItem(kind: .task, text: "Send the notes", sourceSegmentIDs: [segment], sourceStart: 3)

        #expect(task.status == .proposed)
        #expect(task.reviewed(.approved).status == .accepted)
        #expect(task.reviewed(.declined).status == .dismissed)
    }

    @Test
    func identityDependsOnKindSourceAndWordsNotOnSpacingOrCase() {
        let first = MemoryItem(kind: .task, text: "Send the notes.", sourceSegmentIDs: [segment], sourceStart: 3)
        let same = MemoryItem(kind: .task, text: "  send THE notes ", sourceSegmentIDs: [segment], sourceStart: 3)
        let fact = MemoryItem(kind: .fact, text: "Send the notes.", sourceSegmentIDs: [segment], sourceStart: 3)

        #expect(first.id == same.id)
        #expect(first.id != fact.id)
    }

    @Test
    func editingKeepsTheIdentityAndTheExtractedWords() {
        let task = MemoryItem(kind: .task, text: "Send the notes", sourceSegmentIDs: [segment], sourceStart: 3)
        let edited = task.edited(to: "Send the notes to Boris")

        #expect(edited.id == task.id)
        #expect(edited.text == "Send the notes to Boris")
        #expect(edited.extractedText == "Send the notes")
        #expect(edited.status == .proposed)
    }
}

@MainActor
struct MemoryExtractionTests {
    private let project = UUID()

    @Test
    func aConfirmedRecordingGetsSourcedItems() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("We agreed to ship on Friday . I will send the notes by Monday .")
        try library.add(recording)

        await MemoryExtraction(library: library).processPending()

        let memory = try #require(stored(recording, in: library).memory)
        #expect(memory.run?.isComplete == true)
        #expect(memory.items(of: .decision).map(\.sourceStart) == [0])
        #expect(memory.items(of: .task).map(\.status) == [.proposed])
        #expect(memory.items.allSatisfy { $0.sourceSegmentIDs.allSatisfy(Set(recording.segments.map(\.id)).contains) })
    }

    @Test
    func onlyRecordingsWithAConfirmedProjectOrNoProjectAreProcessed() async throws {
        let library = try await makeLibrary()
        let counter = CallCounter()
        let segments = words("We agreed to ship on Friday .")
        let suggested = Recording(title: "Suggested", transcript: segments.plainText, segments: segments, duration: 60, projectID: project)
        var unfiled = Recording(title: "Unfiled", transcript: segments.plainText, segments: segments, duration: 60)
        unfiled.assign(toProject: nil)
        try library.add(suggested)
        try library.add(unfiled)

        await MemoryExtraction(library: library, preferred: { FakeExtractor(counter: counter) }).processPending()

        #expect(await counter.calls == 1)
        #expect(library.recordings.first { $0.id == suggested.id }?.memory == nil)
        #expect(library.recordings.first { $0.id == unfiled.id }?.memory != nil)
    }

    @Test
    func confirmingTheProjectMakesTheRecordingPending() async throws {
        let library = try await makeLibrary()
        let segments = words("We agreed to ship on Friday .")
        let recording = Recording(title: "Call", transcript: segments.plainText, segments: segments, duration: 60, projectID: project)
        try library.add(recording)
        let extraction = MemoryExtraction(library: library)
        #expect(extraction.pendingIDs.isEmpty)

        try library.confirmProjects(of: [recording.id])

        #expect(extraction.pendingIDs == [recording.id])
    }

    @Test
    func unsupportedCandidatesAreCountedButNeverStored() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("We agreed to ship on Friday .")
        try library.add(recording)
        let invented = FakeExtractor { segments in
            [
                ExtractionCandidate(kind: .fact, text: "Revenue tripled in Brazil", citedSegmentIDs: segments.map(\.id)),
                ExtractionCandidate(kind: .decision, text: "Ship on Friday", citedSegmentIDs: [UUID()]),
            ]
        }

        await MemoryExtraction(library: library, preferred: { invented }).processPending()

        let memory = try #require(stored(recording, in: library).memory)
        #expect(memory.items.isEmpty)
        #expect(memory.run?.withheldCount == 2)
    }

    @Test
    func anAcceptedTaskJoinsTheProjectListOnlyAfterReview() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("I will send the notes by Monday .")
        try library.add(recording)
        await MemoryExtraction(library: library).processPending()
        let task = try #require(stored(recording, in: library).memory?.items(of: .task).first)

        #expect(library.acceptedTasks(inProject: project).isEmpty)

        try library.review(task.id, inRecording: recording.id, as: .approved)

        let listed = library.acceptedTasks(inProject: project)
        #expect(listed.map(\.item.id) == [task.id])
        #expect(listed.first?.recordingID == recording.id)
        #expect(library.acceptedTasks(inProject: UUID()).isEmpty)
    }

    @Test
    func aDismissedTaskStaysOffTheList() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("I will send the notes by Monday .")
        try library.add(recording)
        await MemoryExtraction(library: library).processPending()
        let task = try #require(stored(recording, in: library).memory?.items(of: .task).first)

        try library.review(task.id, inRecording: recording.id, as: .declined)

        #expect(library.acceptedTasks(inProject: project).isEmpty)
        #expect(stored(recording, in: library).memory?.item(withID: task.id)?.status == .dismissed)
    }

    @Test
    func aUserEditSurvivesReprocessing() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("I will send the notes by Monday . We agreed to ship on Friday .")
        try library.add(recording)
        let extraction = MemoryExtraction(library: library)
        await extraction.processPending()
        let task = try #require(stored(recording, in: library).memory?.items(of: .task).first)
        try library.edit(task.id, inRecording: recording.id, to: "Send the notes to Boris by Monday")

        await extraction.reprocess(recording.id)

        let memory = try #require(stored(recording, in: library).memory)
        #expect(memory.items(of: .task).map(\.text) == ["Send the notes to Boris by Monday"])
        #expect(memory.items(of: .decision).count == 1)
        #expect(memory.run?.isComplete == true)
    }

    @Test
    func reprocessingDropsUntouchedItemsTheNewPassNoLongerFinds() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("We agreed to ship on Friday . The budget is 40 thousand .")
        try library.add(recording)
        await MemoryExtraction(library: library).processPending()
        let fact = try #require(stored(recording, in: library).memory?.items(of: .fact).first)
        try library.review(fact.id, inRecording: recording.id, as: .approved)
        let decisionsOnly = FakeExtractor { segments in
            TranscriptSentence.sentences(in: segments)
                .filter { $0.text.contains("agreed") }
                .map { ExtractionCandidate(kind: .decision, text: $0.text, citedSegmentIDs: $0.segmentIDs) }
        }

        await MemoryExtraction(library: library, preferred: { decisionsOnly }).reprocess(recording.id)

        let memory = try #require(stored(recording, in: library).memory)
        #expect(memory.items(of: .fact).map(\.status) == [.confirmed])
        #expect(memory.items(of: .decision).count == 1)
    }

    @Test
    func anInterruptedRunResumesWithoutDuplicates() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("We agreed to ship on Friday . The budget is 40 thousand . I will send the notes by Monday .")
        try library.add(recording)
        let interrupting = FakeExtractor(failingOnCall: 2)

        await MemoryExtraction(library: library, preferred: { interrupting }, characterBudget: 10).processPending()

        let interrupted = try #require(stored(recording, in: library).memory)
        #expect(interrupted.run?.completedChunks == 1)
        #expect(interrupted.run?.totalChunks == 3)
        #expect(interrupted.items.count == 1)

        let counter = CallCounter()
        let resumed = MemoryExtraction(library: library, preferred: { FakeExtractor(counter: counter) }, characterBudget: 10)
        await resumed.processPending()

        let memory = try #require(stored(recording, in: library).memory)
        #expect(await counter.calls == 2)
        #expect(memory.run?.isComplete == true)
        #expect(memory.items.count == 3)
        #expect(Set(memory.items.map(\.id)).count == memory.items.count)
    }

    @Test
    func repeatingAChunkAddsNothingTwice() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("We agreed to ship on Friday . I will send the notes by Monday .")
        try library.add(recording)
        await MemoryExtraction(library: library).processPending()
        let first = try #require(stored(recording, in: library).memory)

        let replayed = first.absorbing(first.items.map {
            MemoryItem(kind: $0.kind, text: $0.extractedText, sourceSegmentIDs: $0.sourceSegmentIDs, sourceStart: $0.sourceStart)
        }, withheld: 0, completedChunks: 1)

        #expect(replayed.items == first.items)
    }

    @Test
    func aFailingModelFallsBackToTheExtractivePass() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("We agreed to ship on Friday .")
        try library.add(recording)
        let broken = FakeExtractor { _ in throw FakeExtractorError.unavailable }

        await MemoryExtraction(library: library, preferred: { broken }).processPending()

        #expect(stored(recording, in: library).memory?.items(of: .decision).count == 1)
    }

    @Test
    func aStaleEditorCopyDoesNotEraseExtractedItems() async throws {
        let library = try await makeLibrary()
        let recording = confirmedRecording("We agreed to ship on Friday .")
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)
        await MemoryExtraction(library: library).processPending()

        editor.rename(to: "Launch sync")
        editor.saveNow()

        let saved = stored(recording, in: library)
        #expect(saved.title == "Launch sync")
        #expect(saved.memory?.items(of: .decision).count == 1)
    }

    @Test
    func reviewsAndItemsSurviveARelaunch() async throws {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let source = FakeDeviceKeySource()
        let library = try await makeLibrary(context: context, source: source)
        let recording = confirmedRecording("We agreed to ship on Friday .")
        try library.add(recording)
        await MemoryExtraction(library: library).processPending()
        let decision = try #require(stored(recording, in: library).memory?.items.first)
        try library.review(decision.id, inRecording: recording.id, as: .approved)

        let reopened = try await makeLibrary(context: context, source: source)

        #expect(stored(recording, in: reopened).memory?.item(withID: decision.id)?.status == .confirmed)
    }

    private func confirmedRecording(_ text: String) -> Recording {
        let segments = words(text)
        var recording = Recording(title: "Call", transcript: segments.plainText, segments: segments, duration: 60, projectID: project)
        recording.assign(toProject: project)
        return recording
    }

    private func stored(_ recording: Recording, in library: Library) -> Recording {
        library.recordings.first { $0.id == recording.id } ?? recording
    }

    private func makeLibrary(context: ModelContext? = nil, source: FakeDeviceKeySource = FakeDeviceKeySource()) async throws -> Library {
        let context = try context ?? ModelContext(
            ModelContainer(
                for: EncryptedRecording.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            )
        )
        let library = Library(
            keyRing: LibraryKeyRing(source: source),
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

struct ExtractiveExtractorTests {
    @Test
    func sortsSentencesIntoDecisionsTasksAndFacts() async throws {
        let segments = words("We agreed to ship on Friday . I will send the notes by Monday . The budget is 40 thousand . Nice weather .")
            .map { ExtractionSegment(id: $0.id, start: $0.start, end: $0.end, text: $0.text, speaker: "Anna") }

        let candidates = try await ExtractiveExtractor().candidates(from: segments, language: "en")

        #expect(candidates.map(\.kind) == [.decision, .task, .fact])
        #expect(candidates[1].owner == "Anna")
        #expect(candidates[1].due == "monday")
    }

    @Test
    func windowsBreakBetweenSentences() {
        let segments = words("We agreed to ship on Friday . I will send the notes by Monday .")
            .map { ExtractionSegment(id: $0.id, start: $0.start, end: $0.end, text: $0.text, speaker: nil) }

        let windows = ExtractionWindows.windows(of: segments, characterBudget: 10)

        #expect(windows.count == 2)
        #expect(windows.flatMap { $0 }.map(\.id) == segments.map(\.id))
        #expect(windows[0].last?.text == ".")
    }
}

struct MemoryCompatibilityTests {
    @Test
    func contentSealedBeforeExtractionStillDecodes() throws {
        let json = #"{"title":"Call","transcript":"Hello","segments":[],"speakers":[]}"#

        let content = try JSONDecoder().decode(RecordingContent.self, from: Data(json.utf8))

        #expect(content.memory == nil)
    }

    @Test
    func aRecordingSyncedBeforeExtractionStillDecodes() throws {
        let old = Recording(title: "Call", transcript: "Hello", duration: 10)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "memory")

        let decoded = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.memory == nil)
        #expect(decoded.title == "Call")
    }
}

struct MemoryMergeTests {
    private let segments = words("We agreed to ship on Friday . I will send the notes by Monday .")

    @Test
    func aRegeneratedRunFromAnotherDeviceKeepsTheUsersDecisions() {
        let base = Date(timeIntervalSince1970: 1_000)
        let task = item(.task, "I will send the notes by Monday .", 7...13)
        let decision = item(.decision, "We agreed to ship on Friday .", 0...6)
        let local = memory(
            [task.reviewed(.approved, at: base.addingTimeInterval(10)).edited(to: "Send notes to Boris", at: base.addingTimeInterval(11)), decision],
            startedAt: base
        )
        let remote = memory([decision, task], startedAt: base.addingTimeInterval(60))

        let merged = RecordingMerge.merge(recording(local, updatedAt: base), recording(remote, updatedAt: base.addingTimeInterval(60)))

        let kept = merged.memory?.item(withID: task.id)
        #expect(kept?.status == .accepted)
        #expect(kept?.text == "Send notes to Boris")
        #expect(merged.memory?.run?.startedAt == base.addingTimeInterval(60))
        #expect(merged.memory?.items.count == 2)
    }

    @Test
    func theLaterReviewWinsInEitherOrder() {
        let base = Date(timeIntervalSince1970: 1_000)
        let fact = item(.fact, "We agreed to ship on Friday .", 0...6)
        let confirmed = memory([fact.reviewed(.approved, at: base)], startedAt: base)
        let rejected = memory([fact.reviewed(.declined, at: base.addingTimeInterval(5))], startedAt: base)

        let one = RecordingMemory.merge(confirmed, rejected)
        let other = RecordingMemory.merge(rejected, confirmed)

        #expect(one == other)
        #expect(one?.item(withID: fact.id)?.status == .rejected)
    }

    @Test
    func untouchedItemsFromAnOlderRunAreReplaced() {
        let base = Date(timeIntervalSince1970: 1_000)
        let stale = item(.fact, "We agreed to ship on Friday .", 0...6)
        let fresh = item(.decision, "We agreed to ship on Friday .", 0...6)

        let merged = RecordingMemory.merge(memory([stale], startedAt: base), memory([fresh], startedAt: base.addingTimeInterval(1)))

        #expect(merged?.items.map(\.id) == [fresh.id])
    }

    private func item(_ kind: MemoryKind, _ text: String, _ range: ClosedRange<Int>) -> MemoryItem {
        MemoryItem(kind: kind, text: text, sourceSegmentIDs: segments[range].map(\.id), sourceStart: segments[range.lowerBound].start)
    }

    private func memory(_ items: [MemoryItem], startedAt: Date) -> RecordingMemory {
        RecordingMemory(items: items, run: ExtractionRun(fingerprint: "f", startedAt: startedAt, totalChunks: 1, completedChunks: 1))
    }

    private func recording(_ memory: RecordingMemory, updatedAt: Date) -> Recording {
        Recording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!,
            title: "Call",
            transcript: segments.plainText,
            segments: segments,
            duration: 60,
            updatedAt: updatedAt,
            memory: memory
        )
    }
}

enum FakeExtractorError: Error {
    case unavailable
}

actor CallCounter {
    private(set) var calls = 0

    func increment() -> Int {
        calls += 1
        return calls
    }
}

struct FakeExtractor: Extractor {
    let id = "fake"
    private let make: @Sendable ([ExtractionSegment]) async throws -> [ExtractionCandidate]

    init(_ make: @escaping @Sendable ([ExtractionSegment]) async throws -> [ExtractionCandidate]) {
        self.make = make
    }

    init(counter: CallCounter) {
        make = { segments in
            _ = await counter.increment()
            return Self.sentencesAsFacts(segments)
        }
    }

    init(failingOnCall failing: Int) {
        let counter = CallCounter()
        make = { segments in
            guard await counter.increment() != failing else { throw CancellationError() }
            return Self.sentencesAsFacts(segments)
        }
    }

    func candidates(from segments: [ExtractionSegment], language: String?) async throws -> [ExtractionCandidate] {
        try await make(segments)
    }

    private static func sentencesAsFacts(_ segments: [ExtractionSegment]) -> [ExtractionCandidate] {
        TranscriptSentence.sentences(in: segments).map {
            ExtractionCandidate(kind: .fact, text: $0.text, citedSegmentIDs: $0.segmentIDs)
        }
    }
}
