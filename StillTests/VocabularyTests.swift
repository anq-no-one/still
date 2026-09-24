import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

struct VocabularyCorrectorTests {
    @Test
    func replacesAWholeWordVariantCaseInsensitively() {
        let vocabulary = vocabulary(term: "Kubernetes", variants: ["cooper netties"])
        let segments = [segment("We run this on Cooper Netties every day.")]

        let corrected = VocabularyCorrector.apply(vocabulary, to: segments)

        #expect(corrected[0].correction == "We run this on Kubernetes every day.")
        #expect(corrected[0].displayText == "We run this on Kubernetes every day.")
    }

    @Test
    func normalizesTheCasingOfTheTermItself() {
        let vocabulary = vocabulary(term: "Kubernetes", variants: [])
        let segments = [segment("Ask about kubernetes access.")]

        let corrected = VocabularyCorrector.apply(vocabulary, to: segments)

        #expect(corrected[0].correction == "Ask about Kubernetes access.")
    }

    @Test
    func matchesDiacriticVariants() {
        let vocabulary = vocabulary(term: "François", variants: ["francois"])
        let segments = [segment("Meeting with Francois tomorrow.")]

        let corrected = VocabularyCorrector.apply(vocabulary, to: segments)

        #expect(corrected[0].correction == "Meeting with François tomorrow.")
    }

    @Test
    func matchesCyrillicVariantsCaseInsensitively() {
        let vocabulary = vocabulary(term: "Кубернетес", variants: ["кубер нетис"])
        let segments = [segment("настроили Кубер Нетис вчера")]

        let corrected = VocabularyCorrector.apply(vocabulary, to: segments)

        #expect(corrected[0].correction == "настроили Кубернетес вчера")
    }

    @Test
    func neverMatchesInsideALargerWord() {
        let vocabulary = vocabulary(term: "Kubernetes", variants: ["net"])
        let segments = [segment("Cooper Netties runs on the internet fine.")]

        let corrected = VocabularyCorrector.apply(vocabulary, to: segments)

        #expect(corrected[0].correction == nil)
    }

    @Test
    func theLongestOverlappingVariantWins() {
        let vocabulary = vocabulary(term: "Kubernetes", variants: ["cooper netties", "netties"])
        let segments = [segment("Cooper Netties is the platform.")]

        let corrected = VocabularyCorrector.apply(vocabulary, to: segments)

        #expect(corrected[0].correction == "Kubernetes is the platform.")
    }

    @Test
    func leavesUnrelatedTextAndSegmentsWithoutAMatchUntouched() {
        let vocabulary = vocabulary(term: "Kubernetes", variants: ["cooper netties"])
        let segments = [segment("The weather was nice today.")]

        let corrected = VocabularyCorrector.apply(vocabulary, to: segments)

        #expect(corrected[0].correction == nil)
        #expect(corrected == segments)
    }

    @Test
    func anEmptyVocabularyLeavesSegmentsUntouched() {
        let vocabulary = ProjectVocabulary(projectID: UUID())
        let segments = [segment("Cooper Netties is running.")]

        #expect(VocabularyCorrector.apply(vocabulary, to: segments) == segments)
    }

    @Test
    func aDeletedTermIsNoLongerApplied() {
        var vocabulary = vocabulary(term: "Kubernetes", variants: ["cooper netties"])
        var term = vocabulary.terms[0]
        term.markDeleted()
        vocabulary.upsert(term)
        let segments = [segment("Cooper Netties is running.")]

        #expect(VocabularyCorrector.apply(vocabulary, to: segments)[0].correction == nil)
    }

    private func vocabulary(term: String, variants: [String]) -> ProjectVocabulary {
        var vocabulary = ProjectVocabulary(projectID: UUID())
        vocabulary.upsert(VocabularyTerm(term: term, variants: variants))
        return vocabulary
    }

    private func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(start: 0, end: 1, text: text, language: "en", confidence: 0.9)
    }
}

struct VocabularyTermTests {
    @Test
    func trimsAndDeduplicatesVariantsCaseAndDiacriticInsensitively() {
        let term = VocabularyTerm(term: "François", variants: [" francois ", "François", "Françöis", "Kubernetes"])

        #expect(term.variants == ["francois", "Kubernetes"])
    }

    @Test
    func dropsTheTermsOwnSpellingFromItsVariants() {
        let term = VocabularyTerm(term: "Kubernetes", variants: ["kubernetes", "cooper netties"])

        #expect(term.variants == ["cooper netties"])
    }

    @Test
    func remainsEditableAfterDeduplication() {
        var term = VocabularyTerm(term: "Kubernetes", variants: ["cooper netties"])
        term.setVariants(["cooper netties", "kuber nettis", "cooper netties"])

        #expect(term.variants == ["cooper netties", "kuber nettis"])
    }

    @Test
    func theLaterEditOfEachFieldWins() {
        let base = VocabularyTerm(id: UUID(), term: "Kubernetes", at: Date(timeIntervalSince1970: 0))
        var renamed = base
        renamed.rename(to: "K8s", at: Date(timeIntervalSince1970: 100))
        var revariant = base
        revariant.setVariants(["cooper netties"], at: Date(timeIntervalSince1970: 200))

        let merged = VocabularyTerm.merge(renamed, revariant)

        #expect(merged.term == "K8s")
        #expect(merged.variants == ["cooper netties"])
        #expect(merged == VocabularyTerm.merge(revariant, renamed))
    }

    @Test
    func aTombstoneOutlivesAStaleUndeletedCopy() {
        let base = VocabularyTerm(id: UUID(), term: "Kubernetes", at: Date(timeIntervalSince1970: 0))
        var deleted = base
        deleted.markDeleted(at: Date(timeIntervalSince1970: 100))
        var staleRename = base
        staleRename.rename(to: "K8s", at: Date(timeIntervalSince1970: 50))

        let merged = VocabularyTerm.merge(deleted, staleRename)

        #expect(merged.isDeleted)
    }
}

struct ProjectVocabularyMergeTests {
    @Test
    func termsHeldByOnlySideAreUnioned() {
        let projectID = UUID()
        var first = ProjectVocabulary(projectID: projectID)
        first.upsert(VocabularyTerm(term: "Kubernetes"))
        var second = ProjectVocabulary(projectID: projectID)
        second.upsert(VocabularyTerm(term: "Terraform"))

        let merged = ProjectVocabulary.merge(first, second)
        let reversed = ProjectVocabulary.merge(second, first)

        #expect(Set(merged.terms.map(\.term)) == ["Kubernetes", "Terraform"])
        #expect(Set(merged.terms.map(\.id)) == Set(reversed.terms.map(\.id)))
    }

    @Test
    func aSharedTermMergesFieldByField() {
        let projectID = UUID()
        let id = UUID()
        var first = ProjectVocabulary(projectID: projectID)
        first.upsert(VocabularyTerm(id: id, term: "Kubernetes", at: Date(timeIntervalSince1970: 0)))
        var second = first
        var renamed = second.terms[0]
        renamed.rename(to: "K8s", at: Date(timeIntervalSince1970: 100))
        second.upsert(renamed)

        let merged = ProjectVocabulary.merge(first, second)

        #expect(merged.terms.map(\.term) == ["K8s"])
    }
}

@MainActor
struct LibraryVocabularyTests {
    @Test
    func vocabularyIsStoredSealedAndSurvivesARelaunch() async throws {
        let context = try makeContext()
        let library = try await makeUnlockedLibrary(context: context)
        let project = try library.createProject(named: "Acme", color: .blue)

        var vocabulary = ProjectVocabulary(projectID: project.id)
        vocabulary.upsert(VocabularyTerm(term: "Kubernetes", variants: ["cooper netties"]))
        try library.saveVocabulary(vocabulary)

        let stored = try #require(try context.fetch(FetchDescriptor<EncryptedProjectVocabulary>()).first)
        #expect(!String(decoding: stored.sealedContent, as: UTF8.self).contains("Kubernetes"))

        let reopened = try await makeUnlockedLibrary(context: context)
        #expect(reopened.vocabulary(forProject: project.id).activeTerms.map(\.term) == ["Kubernetes"])
    }

    @Test
    func aTermAppliesOnlyWithinItsOwnProject() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let acme = try library.createProject(named: "Acme", color: .blue)
        let side = try library.createProject(named: "Side job", color: .green)

        var vocabulary = ProjectVocabulary(projectID: acme.id)
        vocabulary.upsert(VocabularyTerm(term: "Kubernetes", variants: ["cooper netties"]))
        try library.saveVocabulary(vocabulary)

        let segments = [TranscriptSegment(start: 0, end: 1, text: "Cooper Netties is up.", language: "en", confidence: 0.9)]

        let inAcme = VocabularyCorrector.apply(library.vocabulary(forProject: acme.id), to: segments)
        let inSide = VocabularyCorrector.apply(library.vocabulary(forProject: side.id), to: segments)
        let inNoProject = VocabularyCorrector.apply(library.vocabulary(forProject: nil), to: segments)

        #expect(inAcme[0].correction == "Kubernetes is up.")
        #expect(inSide[0].correction == nil)
        #expect(inNoProject[0].correction == nil)
    }

    @Test
    func addingATermNeverRewritesAnEarlierRecording() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let project = try library.createProject(named: "Acme", color: .blue)
        let recording = Recording(
            title: "Standup",
            transcript: "Cooper Netties is up.",
            segments: [TranscriptSegment(start: 0, end: 1, text: "Cooper Netties is up.", language: "en", confidence: 0.9)],
            duration: 5,
            projectID: project.id,
            projectAssignedAt: .now
        )
        try library.add(recording)

        var vocabulary = ProjectVocabulary(projectID: project.id)
        vocabulary.upsert(VocabularyTerm(term: "Kubernetes", variants: ["cooper netties"]))
        try library.saveVocabulary(vocabulary)

        let unchanged = try #require(library.storedRecordings.first { $0.id == recording.id })
        #expect(unchanged.segments == recording.segments)
        #expect(unchanged.transcript == recording.transcript)
    }

    private let keySource = FakeDeviceKeySource()

    private func makeUnlockedLibrary(context: ModelContext) async throws -> Library {
        let audioRoot = try Scratch().directory
        let library = Library(
            keyRing: LibraryKeyRing(source: keySource),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { key in
                    MainActor.assumeIsolated { WritingRecorder(root: audioRoot, cipher: LibraryCipher(key: key)) }
                },
                makeProjectRepository: { key in
                    MainActor.assumeIsolated { EncryptedProjectRepository(context: context, key: key) }
                },
                makeVocabularyRepository: { key in
                    MainActor.assumeIsolated { EncryptedProjectVocabularyRepository(context: context, key: key) }
                }
            )
        )
        await library.unlock()
        return library
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EncryptedRecording.self, EncryptedProject.self, EncryptedProjectVocabulary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }
}
