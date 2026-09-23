import Testing
@testable import Still

struct LiveMixTests {
    @Test
    func theMicrophoneAlonePassesThroughUnchanged() {
        var mix = LiveMix(settle: 2, realignAfter: 100)

        mix.add([0.1, 0.2, 0.3], from: .microphone)

        #expect(mix.openStretch(sealingAfter: 10) == LiveMix.Stretch(samples: [0.1, 0.2, 0.3], isSealed: false))
    }

    @Test
    func otherParticipantsAreHeardAlongsideTheMicrophone() {
        var mix = LiveMix(settle: 0, realignAfter: 100)

        mix.add([0, 0], from: .microphone)
        mix.add([0.5], from: .systemAudio)
        mix.add([0.25, 0.25], from: .microphone)

        #expect(mix.openStretch(sealingAfter: 10).samples == [0, 0, 0.75, 0.25])
    }

    @Test
    func aSourceThatJoinsLateStartsWhereTheRecordingIsNotAtTheBeginning() {
        var mix = LiveMix(settle: 0, realignAfter: 100)

        mix.add([0, 0, 0], from: .microphone)
        mix.add([0.5], from: .systemAudio)

        #expect(mix.openStretch(sealingAfter: 10).samples == [0, 0, 0, 0.5])
    }

    @Test
    func simultaneousSpeechIsSummedAndKeptInRange() {
        var mix = LiveMix(settle: 0, realignAfter: 100)

        mix.add([0], from: .microphone)
        mix.add([0.75], from: .systemAudio)
        mix.add([0.5], from: .microphone)

        #expect(mix.openStretch(sealingAfter: 10).samples == [0, 1])
    }

    @Test
    func aSourceThatFallsFarBehindIsMovedUpInsteadOfWritingIntoThePast() {
        var mix = LiveMix(settle: 0, realignAfter: 2)

        mix.add([0], from: .systemAudio)
        mix.add([0, 0, 0, 0, 0], from: .microphone)
        mix.add([0.5], from: .systemAudio)

        #expect(mix.openStretch(sealingAfter: 10).samples == [0, 0, 0, 0, 0, 0, 0.5])
    }

    @Test
    func aStretchSealsOnlyAfterTheSettleMarginSoALateSourceStillLandsInIt() {
        var mix = LiveMix(settle: 2, realignAfter: 100)

        mix.add([0.1, 0.1, 0.1, 0.1], from: .microphone)
        #expect(!mix.openStretch(sealingAfter: 3).isSealed)

        mix.add([0.1], from: .microphone)
        #expect(mix.openStretch(sealingAfter: 3) == LiveMix.Stretch(samples: [0.1, 0.1, 0.1], isSealed: true))
        #expect(mix.openStretch(sealingAfter: 3).samples == [0.1, 0.1])
    }

    @Test
    func sealingKeepsEachSourceWritingAtItsOwnPlace() {
        var mix = LiveMix(settle: 0, realignAfter: 100)

        mix.add([0, 0, 0, 0], from: .microphone)
        mix.add([0], from: .systemAudio)
        _ = mix.openStretch(sealingAfter: 3)
        mix.add([0.5], from: .microphone)
        mix.add([0.25], from: .systemAudio)

        #expect(mix.openStretch(sealingAfter: 10).samples == [0, 0.5, 0.25])
    }
}
