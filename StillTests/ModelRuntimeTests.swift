import Foundation
import Testing
import Synchronization
@testable import Still

private actor RuntimeConcurrencyProbe {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var completed = 0

    func run() async {
        active += 1
        maximumActive = max(maximumActive, active)
        for _ in 0..<30 { await Task.yield() }
        active -= 1
        completed += 1
    }
}

private actor RuntimeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var opened = false

    func hold() async {
        entered = true
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

struct ModelRuntimeTests {
    @Test
    func modelRequestsRemainExclusiveAcrossSuspension() async throws {
        let queue = ModelExecutionQueue()
        let probe = RuntimeConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { try await queue.perform { await probe.run() } }
            }
            try await group.waitForAll()
        }
        #expect(await probe.maximumActive == 1)
        #expect(await probe.completed == 12)
    }

    @Test
    func failedRequestReleasesTheNextRequest() async throws {
        struct Failure: Error {}
        let queue = ModelExecutionQueue()
        do {
            try await queue.perform { throw Failure() }
            Issue.record("Expected the request to fail")
        } catch is Failure {}
        let result = try await queue.perform { 42 }
        #expect(result == 42)
    }

    @Test
    func cancelledRequestDoesNotStartInference() async throws {
        let queue = ModelExecutionQueue()
        let probe = RuntimeConcurrencyProbe()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            try await queue.perform { await probe.run() }
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(await probe.completed == 0)
        #expect(try await queue.perform { 42 } == 42)
    }

    @Test
    func failedGenerationReclaimsTemporaryMemory() async throws {
        struct Failure: Error {}
        let phases = Mutex<[String]>([])
        let queue = ModelExecutionQueue(
            prepare: { phases.withLock { $0.append("prepare") } },
            cleanup: { phases.withLock { $0.append("cleanup") } }
        )
        do {
            try await queue.perform {
                phases.withLock { $0.append("generate") }
                throw Failure()
            }
            Issue.record("Expected failure")
        } catch is Failure {}
        #expect(phases.withLock { $0 } == ["prepare", "generate", "cleanup"])
    }


    @Test
    func modelAvailabilityIsNotPromotedToAnActionItem() throws {
        let source = ExtractionSegment(id: UUID(), start: 0, end: 1, text: "Tomorrow I will be on PTO.", speaker: "Anna", language: "en")
        let candidates = try LocalModelExtractor.groundedCandidates(
            #"{"items":[{"kind":"task","text":"Be on PTO tomorrow","lines":[1],"owner":"Anna","due":"tomorrow"}]}"#,
            sentences: TranscriptSentence.sentences(in: [source])
        )
        #expect(candidates.map(\.kind) == [.fact])
        #expect(candidates.first?.owner == nil)
        #expect(candidates.first?.due == nil)
    }

    @Test
    func modelImperativeNeedsACommitmentInItsCitedSource() throws {
        let source = ExtractionSegment(id: UUID(), start: 0, end: 1, text: "Can we send the release notes?", speaker: "Anna", language: "en")
        let candidates = try LocalModelExtractor.groundedCandidates(
            #"{"items":[{"kind":"task","text":"Send the release notes","lines":[1],"owner":"Anna","due":""}]}"#,
            sentences: TranscriptSentence.sentences(in: [source])
        )
        #expect(candidates.isEmpty)
    }

    @Test
    func conciseModelActionKeepsItsSupportedCommitment() throws {
        let source = ExtractionSegment(id: UUID(), start: 0, end: 1, text: "I will send the release notes tomorrow.", speaker: "Anna", language: "en")
        let candidates = try LocalModelExtractor.groundedCandidates(
            #"{"items":[{"kind":"task","text":"Send the release notes","lines":[1],"owner":"Anna","due":"tomorrow"}]}"#,
            sentences: TranscriptSentence.sentences(in: [source])
        )
        #expect(candidates.map(\.kind) == [.task])
        #expect(candidates.first?.owner == "Anna")
    }


    @Test
    func cancelledWaitingRequestDoesNotRunOrBlockLaterRequests() async throws {
        let queue = ModelExecutionQueue()
        let gate = RuntimeGate()
        let probe = RuntimeConcurrencyProbe()
        let active = Task { try await queue.perform { await gate.hold() } }
        while !(await gate.entered) { await Task.yield() }
        let waiting = Task { try await queue.perform { await probe.run() } }
        while await queue.waitingRequestCount == 0 { await Task.yield() }
        waiting.cancel()
        await gate.release()
        try await active.value
        do {
            try await waiting.value
            Issue.record("Expected the waiting request to be cancelled")
        } catch is CancellationError {}
        #expect(await probe.completed == 0)
        #expect(try await queue.perform { 42 } == 42)
    }

    @Test
    func nonEnglishModelCommitmentsAreNotRejectedByEnglishHeuristics() throws {
        let source = ExtractionSegment(id: UUID(), start: 0, end: 1, text: "Wyślę raport jutro.", speaker: "Anna", language: "pl")
        let candidates = try LocalModelExtractor.groundedCandidates(
            #"{"items":[{"kind":"task","text":"Wysłać raport","lines":[1],"owner":"Anna","due":"jutro"}]}"#,
            sentences: TranscriptSentence.sentences(in: [source]),
            language: "pl"
        )
        #expect(candidates.map(\.kind) == [.task])
    }

}
