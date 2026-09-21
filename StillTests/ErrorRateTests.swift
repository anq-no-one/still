import Foundation
import Testing
@testable import Still

struct WordErrorRateTests {
    @Test
    func aPerfectTranscriptScoresZero() {
        #expect(WordErrorRate.value(
            reference: "We agreed to delay the launch",
            hypothesis: "we agreed to delay the launch"
        ) == 0)
    }

    @Test
    func ignoresPunctuationAndCase() {
        #expect(WordErrorRate.value(
            reference: "We agreed. To delay!",
            hypothesis: "we agreed to delay"
        ) == 0)
    }

    @Test
    func countsSubstitutionsInsertionsAndDeletions() {
        #expect(WordErrorRate.value(reference: "one two three four", hypothesis: "one two four") == 0.25)
        #expect(WordErrorRate.value(reference: "one two three four", hypothesis: "one two six four") == 0.25)
        #expect(WordErrorRate.value(reference: "one two three four", hypothesis: "one two three five four") == 0.25)
    }

    @Test
    func anEmptyTranscriptOfRealSpeechScoresOne() {
        #expect(WordErrorRate.value(reference: "one two three", hypothesis: "") == 1)
    }

    @Test
    func theGateAcceptsTwelvePercentForEnglishAndEighteenForTheRest() {
        #expect(ReleaseGate.passes(wordErrorRate: 0.12, language: "en"))
        #expect(!ReleaseGate.passes(wordErrorRate: 0.13, language: "en"))
        #expect(ReleaseGate.passes(wordErrorRate: 0.18, language: "pl"))
        #expect(!ReleaseGate.passes(wordErrorRate: 0.19, language: "uk"))
    }
}

struct DiarizationErrorRateTests {
    @Test
    func perfectSeparationScoresZeroEvenWithDifferentLabels() {
        let reference = [
            SpeakerSpan(speaker: "Anna", start: 0, end: 10),
            SpeakerSpan(speaker: "Ben", start: 10, end: 20),
        ]
        let hypothesis = [
            SpeakerSpan(speaker: "Speaker 1", start: 0, end: 10),
            SpeakerSpan(speaker: "Speaker 2", start: 10, end: 20),
        ]

        #expect(DiarizationErrorRate.value(reference: reference, hypothesis: hypothesis) == 0)
    }

    @Test
    func countsTimeGivenToTheWrongGroup() {
        let reference = [
            SpeakerSpan(speaker: "Anna", start: 0, end: 10),
            SpeakerSpan(speaker: "Ben", start: 10, end: 20),
        ]
        let hypothesis = [
            SpeakerSpan(speaker: "Speaker 1", start: 0, end: 15),
            SpeakerSpan(speaker: "Speaker 2", start: 15, end: 20),
        ]

        #expect(DiarizationErrorRate.value(reference: reference, hypothesis: hypothesis) == 0.25)
    }

    @Test
    func oneGroupForEveryoneScoresHalfOnTwoEvenSpeakers() {
        let reference = [
            SpeakerSpan(speaker: "Anna", start: 0, end: 10),
            SpeakerSpan(speaker: "Ben", start: 10, end: 20),
        ]
        let hypothesis = [SpeakerSpan(speaker: "Speaker 1", start: 0, end: 20)]

        #expect(DiarizationErrorRate.value(reference: reference, hypothesis: hypothesis) == 0.5)
    }

    @Test
    func noSeparationAtAllScoresOne() {
        let reference = [SpeakerSpan(speaker: "Anna", start: 0, end: 10)]

        #expect(DiarizationErrorRate.value(reference: reference, hypothesis: []) == 1)
    }

    @Test
    func theGateAcceptsTwentyPercent() {
        #expect(ReleaseGate.passes(diarizationErrorRate: 0.20))
        #expect(!ReleaseGate.passes(diarizationErrorRate: 0.21))
    }
}
