import Foundation
import Testing
@testable import Still

struct DisfluencyFilterTests {
    @Test
    func englishFillersFallOut() {
        #expect(DisfluencyFilter.cleaned("Um we should uh ship it", language: "en") == "we should ship it")
    }

    @Test
    func fillerMatchingIgnoresCase() {
        #expect(DisfluencyFilter.cleaned("UM the plan", language: "en") == "the plan")
    }

    @Test
    func repeatedWordsCollapseToOne() {
        #expect(DisfluencyFilter.cleaned("the the plan", language: "en") == "the plan")
        #expect(DisfluencyFilter.cleaned("I I I think so", language: "en") == "I think so")
    }

    @Test
    func otherLanguagesUseTheirOwnFillers() {
        #expect(DisfluencyFilter.cleaned("Ähm wir sollten das tun", language: "de") == "wir sollten das tun")
        #expect(DisfluencyFilter.cleaned("Euh on devrait le faire", language: "fr") == "on devrait le faire")
        #expect(DisfluencyFilter.cleaned("Эм нужно запустить", language: "ru") == "нужно запустить")
    }

    @Test
    func unknownLanguagesFallBackToEnglish() {
        #expect(DisfluencyFilter.cleaned("um hello", language: "xx") == "hello")
        #expect(DisfluencyFilter.cleaned("um hello", language: nil) == "hello")
    }

    @Test
    func punctuationOnlyTokensAreKept() {
        #expect(DisfluencyFilter.cleaned("Ship it .", language: "en") == "Ship it .")
    }

    @Test
    func fillerOnlyTextIsDetected() {
        #expect(DisfluencyFilter.isFillerOnly("um uh", language: "en"))
        #expect(!DisfluencyFilter.isFillerOnly("um the plan", language: "en"))
        #expect(!DisfluencyFilter.isFillerOnly("   ", language: "en"))
    }

    @Test
    func sentencesSkipFillerOnlySegmentsButKeepTheirTiming() {
        let segments = [
            TranscriptSegment(start: 3, end: 4, text: "um uh", language: "en", confidence: 0.9),
            TranscriptSegment(start: 4, end: 6, text: "We ship Friday.", language: "en", confidence: 0.9),
        ]

        let sentences = ExtractiveNoteGenerator.sentences(in: segments)

        #expect(sentences.count == 1)
        #expect(sentences[0].text == "We ship Friday.")
        #expect(sentences[0].start == 4)
        #expect(segments[0].displayText == "um uh")
    }

    @Test
    func memorySentencesSkipFillersAcrossSpeakers() {
        let segments = [
            ExtractionSegment(id: UUID(), start: 0, end: 1, text: "um", speaker: "Anna", language: "en"),
            ExtractionSegment(id: UUID(), start: 1, end: 2, text: "We agreed.", speaker: "Anna", language: "en"),
        ]

        let sentences = TranscriptSentence.sentences(in: segments)

        #expect(sentences.count == 1)
        #expect(sentences[0].text == "We agreed.")
        #expect(sentences[0].segmentIDs == [segments[1].id])
    }

    @Test
    func titlesSkipLeadingFillers() {
        #expect(RecordingTitle.from(transcript: "Um uh the quarterly plan") == "the quarterly plan")
    }

    @Test
    func aTranscriptOfOnlyFillersFallsBackToTheDate() {
        let locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dated = RecordingTitle.from(transcript: "   ", date: Date(timeIntervalSince1970: 0), calendar: calendar)

        #expect(RecordingTitle.from(transcript: "um uh", language: "en") == RecordingTitle.from(transcript: "", language: "en"))
        #expect(!dated.isEmpty)
    }

    @Test
    func notesQuoteCleanedText() async throws {
        let segments = words("Um we decided to delay the launch .")

        let note = try await ExtractiveNoteGenerator().note(template: .meeting, segments: segments)

        #expect(note.decisions.map(\.text) == ["we decided to delay the launch ."])
        #expect(NoteSchema.isGrounded(note, in: segments))
    }
}
