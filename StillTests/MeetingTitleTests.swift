import Foundation
import Testing
@testable import Still

@MainActor
struct MeetingTitleFinalizerTests {
    private func finalizer(
        makeTitle: (@MainActor @Sendable (TitleRequest) async -> String?)?
    ) -> RecordingFinalizer {
        RecordingFinalizer(
            finalTranscription: FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600),
            speakerSeparation: .trackBased,
            noteBuilder: GroundedNoteBuilder(),
            library: SpyRecordingLibrary(),
            makeTitle: makeTitle
        )
    }

    private func draft(meetingTitle: String? = nil) -> RecordingFinalizer.Draft {
        var draft = RecordingFinalizer.Draft(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), duration: 5)
        draft.meetingTitle = meetingTitle
        return draft
    }

    @Test
    func theCalendarEventNamesTheMeetingWhenNoModelIsAvailable() async throws {
        let recording = try await finalizer(makeTitle: { _ in nil }).build(draft(meetingTitle: "Design Huddle"))

        #expect(recording.title == "Design Huddle")
        #expect(recording.titleSource == .automatic)
    }

    @Test
    func theModelHearsTheCalendarTitleAsAHint() async throws {
        let heard = Box<TitleRequest?>(nil)

        let recording = try await finalizer(makeTitle: { request in
            heard.value = request
            return "Onboarding Screens Review"
        }).build(draft(meetingTitle: "Design Huddle"))

        #expect(recording.title == "Onboarding Screens Review")
        #expect(heard.value?.calendarTitle == "Design Huddle")
        #expect(heard.value?.segments.isEmpty == false)
    }

    @Test
    func anAutomaticTitleIsMarkedAutomatic() async throws {
        let recording = try await finalizer(makeTitle: nil).build(draft())

        #expect(recording.titleSource == .automatic)
    }
}

struct MeetingTitleTextTests {
    @Test
    func theFallbackSkipsGreetingsAndSmallTalk() {
        let title = RecordingTitle.from(
            transcript: "Hey, how are you? Good, thanks. Can you hear me? Let's review the new onboarding screens for the design system."
        )

        #expect(title == "Let's review the new onboarding screens")
    }

    @Test
    func theFallbackPrefersWhatTheCallKeepsComingBackTo() {
        let title = RecordingTitle.from(
            transcript: """
            Hi everyone. I had lunch with my cousin yesterday. The pricing page needs a new layout. \
            We should test the pricing page with customers. The pricing page ships on Friday.
            """
        )

        #expect(title.localizedCaseInsensitiveContains("pricing page"))
    }

    @Test
    func aGreetingOnlyCallFallsBackToTheDate() {
        let title = RecordingTitle.from(transcript: "Hey, how are you? Good, thanks. Bye.", date: Date(timeIntervalSince1970: 0))

        #expect(title == RecordingTitle.from(transcript: "", date: Date(timeIntervalSince1970: 0)))
    }

    @Test
    func modelOutputIsCleanedUp() {
        #expect(TitleText.cleaned("  \"Onboarding Screens Review.\" ") == "Onboarding Screens Review")
    }

    @Test(arguments: ["", "Hey, how are you?", "Line one\nLine two", String(repeating: "word ", count: 20)])
    func badModelOutputIsRejected(output: String) {
        #expect(TitleText.cleaned(output) == nil)
    }

    @Test
    func theExcerptCoversTheWholeCall() {
        let sentences = (1...400).map { "Point number \($0) is about topic \($0) ." }.joined(separator: " ")
        let request = TitleRequest(segments: words(sentences), calendarTitle: nil, language: "en")

        let excerpt = request.excerpt(characterBudget: 1_500)

        #expect(excerpt.count <= 1_500)
        #expect(excerpt.contains("Point number 1 "))
        #expect(excerpt.contains("topic 400"))
        #expect((150...250).contains { excerpt.contains("topic \($0) ") || excerpt.contains("topic \($0).") })
    }

    @Test
    func theExcerptLeavesOutSmallTalk() {
        let request = TitleRequest(segments: words("Hi Phil , how are you ? We ship the export feature ."), calendarTitle: nil, language: "en")

        #expect(request.excerpt(characterBudget: 1_000) == "We ship the export feature.")
    }
}

struct TitleSourceTests {
    @Test
    func anOldRecordingWithItsFirstWordsAsTitleCountsAsAutomatic() {
        let recording = Recording(title: "Hey How are you", transcript: "Hey how are you doing today? Fine.", duration: 60)

        #expect(!recording.isTitleChosenByUser)
    }

    @Test
    func anOldRecordingWithADifferentTitleCountsAsTheUsers() {
        let recording = Recording(title: "Board prep", transcript: "Hey how are you doing today? Fine.", duration: 60)

        #expect(recording.isTitleChosenByUser)
    }

    @Test
    func aUserTitleWinsASyncMergeOverAnAutomaticOne() {
        let id = UUID()
        var local = Recording(id: id, title: "Board prep", transcript: "x", duration: 60, updatedAt: Date(timeIntervalSince1970: 1))
        local.titleSource = .user
        var remote = Recording(id: id, title: "Quarterly Numbers Review", transcript: "x", duration: 60, updatedAt: Date(timeIntervalSince1970: 2))
        remote.titleSource = .automatic

        let merged = RecordingMerge.merge(local, remote)

        #expect(merged.title == "Board prep")
        #expect(merged.titleSource == .user)
    }

    @Test
    func twoAutomaticTitlesFollowTheNewerWrite() {
        let id = UUID()
        var local = Recording(id: id, title: "Hey how are you", transcript: "x", duration: 60, updatedAt: Date(timeIntervalSince1970: 1))
        local.titleSource = .automatic
        var remote = Recording(id: id, title: "Quarterly Numbers Review", transcript: "x", duration: 60, updatedAt: Date(timeIntervalSince1970: 2))
        remote.titleSource = .automatic

        #expect(RecordingMerge.merge(local, remote).title == "Quarterly Numbers Review")
    }
}

final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
