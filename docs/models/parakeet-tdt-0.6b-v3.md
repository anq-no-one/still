# Parakeet TDT 0.6B V3 — default production ASR

Still transcribes the final high-accuracy pass with NVIDIA Parakeet TDT 0.6B V3, loaded through
FluidAudio's Core ML runtime. Whisper stays out of the product interface and exists only as the
hidden fallback described below.

## Pinned artifacts

| Item | Value |
|---|---|
| Model weights | [`FluidInference/parakeet-tdt-0.6b-v3-coreml`](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) |
| Pinned revision | `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe` (2026-08-19) |
| Upstream checkpoint | [`nvidia/parakeet-tdt-0.6b-v3`](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) at `541d1f99c6b0c3cd0b11a95167540bb8edefd82b` |
| Conversion | NVIDIA NeMo checkpoint exported to Core ML `.mlmodelc` bundles by FluidInference |
| Tokenizer | `parakeet_vocab.json`, a 1024-entry SentencePiece id-to-token map shipped in the same repository |
| Runtime | [FluidAudio](https://github.com/FluidInference/FluidAudio) `v0.15.8` (`87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc`) |
| Model license | CC-BY-4.0 |
| Runtime license | Apache-2.0 |
| Installed size | 483,105,645 bytes (460.7 MiB) across 21 files |

The default encoder precision is `int8`. FluidAudio also publishes `Encoder_v2.mlmodelc` (`int8-v2`,
+149 MB) and `EncoderInt4.mlmodelc`. Still keeps `int8` until the device gates below compare them,
because the encoder rebuild is opt-in upstream and unmeasured here.

### Required file set and SHA-256

`ModelNames.ASR.requiredModelsV3(precision: .int8)` resolves to the preprocessor, encoder, decoder,
V3 joint model, and vocabulary. Every digest below was computed from the downloaded revision and
matched the publisher's Git LFS object id where one exists.

| `Decoder.mlmodelc/analytics/coremldata.bin` | 243 | `4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350` |
| `Decoder.mlmodelc/coremldata.bin` | 554 | `18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99` |
| `Decoder.mlmodelc/metadata.json` | 3,427 | `a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9` |
| `Decoder.mlmodelc/model.mil` | 13,110 | `ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35` |
| `Decoder.mlmodelc/weights/weight.bin` | 23,604,992 | `48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41` |
| `Encoder.mlmodelc/analytics/coremldata.bin` | 243 | `42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105` |
| `Encoder.mlmodelc/coremldata.bin` | 485 | `d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86` |
| `Encoder.mlmodelc/metadata.json` | 2,921 | `da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9` |
| `Encoder.mlmodelc/model.mil` | 959,769 | `ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808` |
| `Encoder.mlmodelc/weights/weight.bin` | 445,187,200 | `e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421` |
| `JointDecisionv3.mlmodelc/analytics/coremldata.bin` | 243 | `26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c` |
| `JointDecisionv3.mlmodelc/coremldata.bin` | 521 | `f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342` |
| `JointDecisionv3.mlmodelc/metadata.json` | 3,453 | `d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f` |
| `JointDecisionv3.mlmodelc/model.mil` | 11,775 | `be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d` |
| `JointDecisionv3.mlmodelc/weights/weight.bin` | 12,642,764 | `4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e` |
| `Preprocessor.mlmodelc/analytics/coremldata.bin` | 243 | `c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d` |
| `Preprocessor.mlmodelc/coremldata.bin` | 486 | `dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d` |
| `Preprocessor.mlmodelc/metadata.json` | 2,841 | `2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf` |
| `Preprocessor.mlmodelc/model.mil` | 28,181 | `4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93` |
| `Preprocessor.mlmodelc/weights/weight.bin` | 491,072 | `129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea` |
| `parakeet_vocab.json` | 151,122 | `7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735` |
| | **483,105,645** | |

Verify a local install with:

```sh
find <model-directory> -type f -print0 | sort -z | xargs -0 shasum -a 256
```

## Language support

The checkpoint advertises English and 24 further European languages. Still splits them by the
evidence it will hold at release.

| Support | Languages |
|---|---|
| Verified | English, Polish, Russian, Ukrainian, German, French, Spanish, Italian |
| Best-effort | Bulgarian, Croatian, Czech, Danish, Dutch, Estonian, Finnish, Greek, Hungarian, Latvian, Lithuanian, Maltese, Portuguese, Romanian, Slovak, Slovenian, Swedish |

Verified means the language is part of the locked evaluation set and must meet the release word
error rate gate. Best-effort means the model accepts the language and Still exposes it, but no
quality gate covers it.

## Whisper fallback

Whisper is not a user-selectable engine and is absent from the product interface. Still routes a
recording to Whisper only when Parakeet cannot serve it at all:

- the detected language is outside the 25 the checkpoint supports, or
- the device or model pack cannot load the Core ML runtime.

Every other recording uses Parakeet. The fallback never appears as a setting, a prompt, or a
quality choice.

## Known accuracy risks

- The default palettized encoder corrupted Ukrainian tokens under specific right-context
  ([FluidAudio #760](https://github.com/FluidInference/FluidAudio/issues/760)). The `int8-v2`
  rebuild fixed the reported cuts but is not the upstream default.
- Certain cuts decode to blank output in both the Core ML and the full-precision MLX runtimes
  ([FluidAudio #909](https://github.com/FluidInference/FluidAudio/issues/909)), so the cause is
  model behavior rather than conversion alone. The recovery ladder in
  [#910](https://github.com/FluidInference/FluidAudio/pull/910) recovered 10 of 11 reproduced cuts.

Both risks are inputs to the device gates, not blockers for pinning the artifact.

## Open gate: device measurements

This document does not approve Parakeet for release. The measurements required by the release gate
have not been taken, and no number in this repository may stand in for them.

| Device | Required measurements |
|---|---|
| iPhone 13 | WER per verified language, time to first draft, real-time factor, peak memory, thermal state, energy impact |
| Base M1 Mac | the same set |

Each device must also run the `int8` and `int8-v2` encoders against the same cuts so the precision
choice rests on measured word error rate rather than the upstream default. Running these gates
needs the physical devices and the locked evaluation set, neither of which exists yet.
