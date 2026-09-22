# Audio and local-intelligence release gates

## Thresholds

| Gate | Threshold | Where it lives |
|---|---|---|
| Word error rate, English | ≤ 12% median | `ReleaseGate.englishWordErrorRate` |
| Word error rate, PL RU UK DE FR ES IT | ≤ 18% median | `ReleaseGate.verifiedLanguageWordErrorRate` |
| Four-speaker diarization error rate | ≤ 20% | `ReleaseGate.diarizationErrorRate` |
| First partial transcript | ≤ 2s | `ReleaseGate.firstPartialSeconds` |
| Draft behind speech | ≤ 2s | `ReleaseGate.draftLagSeconds` |
| One hour processed, iPhone 13 | ≤ 10 min | `ReleaseGate.hourProcessingOnIPhone13` |
| One hour processed, base M1 | ≤ 4 min | `ReleaseGate.hourProcessingOnBaseM1` |

## What exists

The measurement is implemented and tested. `WordErrorRate` is token edit distance over normalized
text, and `DiarizationErrorRate` is the share of spoken time attributed to the wrong group, with
group names matched by whichever pairing explains the most time. `ErrorRateTests` checks both
against hand-worked cases, including the label-independence a real diarizer needs.

## What is missing, and why no number can be reported yet

**No measurement has been taken.** Reporting one would require inventing it, and a fabricated
benchmark is worse than an absent one because it would be believed.

Three things are needed:

1. **The locked evaluation set.** Reference transcripts and speaker spans for the eight verified
   languages, covering accents, distant microphones, background noise, crosstalk, proper nouns, and
   long silence. None of it exists in this repository.
2. **The devices.** An iPhone 13 and a base M1 Mac, since the gates are defined on the minimum
   supported hardware and no other machine can stand in.
3. **The Parakeet runtime.** `docs/models/parakeet-tdt-0.6b-v3.md` pins the artifact and verifies
   its digests, but FluidAudio is not yet linked and transcription still runs through Apple's
   on-device recognizer. Measuring today would measure the wrong engine.

Peak memory, thermal state, and energy come from an Instruments run on those devices, which also
cannot be produced here.

Both encoder precisions (`int8` and `int8-v2`) must be measured against the same cuts, because the
upstream default corrupted Ukrainian tokens in FluidAudio issue #760 and the choice belongs to
evidence rather than to the upstream default.

## Known defect: two audio engines share one microphone

`MicrophoneRecorder` and `LiveTranscriber` each own an `AVAudioEngine` and each install a tap on
`inputNode`. During a Pro recording both start, so two engines capture the same hardware input in
one process.

`RecordingWorkflow.start()` starts the recorder first and the recognizer second. A recognizer that
will not start now costs only the live preview: the recording continues, the draft explains what
stopped, and the transcript comes from the journaled audio on save. So the contention can no longer
prevent a Pro user from recording, but two engines still compete for one input and that is worth
removing.

This has not been observed, because no build has run on a device with a microphone. It is listed
here rather than fixed because the correct fix reshapes the capture seam: one engine owns the
input, converts once, and fans the buffers out to the chunk writer and the recognizer. That
crosses an actor boundary — the tap runs on the audio thread while the session is main-actor
isolated — so it needs a real device to verify rather than a blind refactor.

Measure it on the first device run, before the accuracy gates above.
