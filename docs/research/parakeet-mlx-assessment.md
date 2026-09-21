# Parakeet MLX assessment

Date: 2026-09-21

## Decision

Still should use **Parakeet TDT 0.6B V3 as the default high-accuracy transcription model**, but it should not embed the `senstella/parakeet-mlx` Python package in either shipping app.

The production runtime should start with **FluidAudio and its Core ML Parakeet V3 pipeline** on iOS and macOS. Still should keep `parakeet-mlx` as a development reference, benchmark runner, and accuracy oracle on Apple Silicon Macs.

The archived Swift MLX port should not be adopted.

## Fit summary

| Option | Shipping fit | Best use in Still | Main reason |
|---|---:|---|---|
| `senstella/parakeet-mlx` | Low | Mac-only benchmark and reference implementation | Accurate, current, and feature-rich, but distributed as a Python package with MLX and other Python dependencies |
| `FluidInference/swift-parakeet-mlx` | Reject | Source reference only | Archived, tested only with Parakeet V2, resource-intensive, and has no test target |
| FluidAudio Parakeet V3 | High, pending device gates | Shared iOS/macOS production runtime | Native Swift/Core ML, actively maintained, offline-capable, multilingual, timestamped, and tested |

## What `parakeet-mlx` provides

The current reviewed revision is [`b78130e`](https://github.com/senstella/parakeet-mlx/tree/b78130e3aa1788e89707ec164adbea8865316aaf). Package version `0.5.2` requires Python 3.10 or newer and depends on MLX, NumPy, librosa, Hugging Face Hub, dacite, and Typer. Its CLI also expects `ffmpeg` to be installed. The implementation is Apache-2.0 licensed. Sources include the project [README](https://github.com/senstella/parakeet-mlx/blob/b78130e3aa1788e89707ec164adbea8865316aaf/README.md), [`pyproject.toml`](https://github.com/senstella/parakeet-mlx/blob/b78130e3aa1788e89707ec164adbea8865316aaf/pyproject.toml), and [license](https://github.com/senstella/parakeet-mlx/blob/b78130e3aa1788e89707ec164adbea8865316aaf/LICENSE).

Useful capabilities include:

- Parakeet TDT, RNNT, CTC, and hybrid model loading.
- Greedy and beam decoding for supported TDT models.
- Sentence and word timestamps.
- Long-recording chunking with overlap.
- Local attention to reduce intermediate memory use.
- Streaming input with finalized and draft tokens.

The project still lists continuous-context chunking as incomplete. The repository also has no automated test directory or test target at the reviewed revision. See the [streaming API and roadmap](https://github.com/senstella/parakeet-mlx/blob/b78130e3aa1788e89707ec164adbea8865316aaf/README.md#streaming-transcription) and the [chunking implementation](https://github.com/senstella/parakeet-mlx/blob/b78130e3aa1788e89707ec164adbea8865316aaf/parakeet_mlx/parakeet.py).

## Why the Python package should not ship

- Still would need to bundle and sign a Python runtime plus several native and Python dependencies.
- The package exposes Python and CLI APIs rather than a stable native Swift SDK.
- The CLI depends on an external `ffmpeg` installation.
- The package targets Apple Silicon through Python MLX. It does not provide a supported iPhone or iPad integration path.
- A Python runtime complicates sandboxing, App Store review, crash diagnosis, background execution, model storage, and app size.
- The original MLX V3 model stores about **2.51 GB** in `model.safetensors`. The exact file size is 2,508,288,736 bytes in the [Hugging Face repository](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/tree/main).

These constraints are acceptable for an internal Mac benchmark tool. They are poor defaults for a polished Universal Purchase app.

## Swift MLX port

The original Swift port now resolves to [`FluidInference/swift-parakeet-mlx`](https://github.com/FluidInference/swift-parakeet-mlx). The repository is archived. Its own README says the implementation did not reach the desired performance, was too resource-intensive for production, and was superseded by the Core ML work in FluidAudio. It was tested only with `parakeet-tdt-0.6b-v2`, requires about 2.5 GB for that model, and still needs proper caching. See its [README](https://github.com/FluidInference/swift-parakeet-mlx/blob/8123e7b4b3877476d1a3b187d68ee2f6e4c903b7/README.md) and [Swift package manifest](https://github.com/FluidInference/swift-parakeet-mlx/blob/8123e7b4b3877476d1a3b187d68ee2f6e4c903b7/Package.swift).

The package declares iOS 16 and macOS 14 targets, but it has no test target. The archive status, V2-only validation, incomplete cache path, and upstream production warning rule it out for Still.

## FluidAudio production path

The reviewed FluidAudio revision is [`5343241`](https://github.com/FluidInference/FluidAudio/tree/5343241cd8a7576890e50925dec666bafc89d324). The project is an active Apache-2.0 Swift package targeting iOS 17 and macOS 14. Its Parakeet V3 runtime uses Core ML and supports the same 25 European languages as the upstream model, including English, Polish, Russian, and Ukrainian. Sources include the [package manifest](https://github.com/FluidInference/FluidAudio/blob/5343241cd8a7576890e50925dec666bafc89d324/Package.swift), [model guide](https://github.com/FluidInference/FluidAudio/blob/5343241cd8a7576890e50925dec666bafc89d324/Documentation/Models.md), and [ASR guide](https://github.com/FluidInference/FluidAudio/blob/5343241cd8a7576890e50925dec666bafc89d324/Documentation/ASR/GettingStarted.md).

FluidAudio provides:

- Batch and sliding-window Parakeet V3 transcription.
- Token and word timing data.
- Long-recording window stitching and cancellation.
- Local loading from a caller-controlled directory.
- A hard offline mode that rejects network fetches.
- Core ML compute placement for Apple Neural Engine and GPU tradeoffs.
- VAD and multiple speaker-diarization pipelines in the same native package.
- Extensive ASR, timestamp, window-merging, offline-mode, and regression tests.

The default V3 runtime file set is about **482 MB** before filesystem and packaging overhead. It consists of the preprocessor, default encoder, decoder, V3 joint model, and vocabulary. The safer `int8-v2` candidate raises that set to about **631 MB** because its encoder is larger. The required files are defined in [`AsrModels`](https://github.com/FluidInference/FluidAudio/blob/5343241cd8a7576890e50925dec666bafc89d324/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift) and [`ModelNames`](https://github.com/FluidInference/FluidAudio/blob/5343241cd8a7576890e50925dec666bafc89d324/Sources/FluidAudio/ModelNames.swift). Artifact sizes come from the [Core ML model repository](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/main).

The offline boundary is implemented by `ModelHub.offlineMode`. Missing local files and attempted network access return typed errors instead of silently fetching. See the [offline-mode documentation](https://github.com/FluidInference/FluidAudio/blob/5343241cd8a7576890e50925dec666bafc89d324/README.md#offline-only-mode---refuse-every-network-fetch-bundle-your-own-models) and [offline tests](https://github.com/FluidInference/FluidAudio/blob/5343241cd8a7576890e50925dec666bafc89d324/Tests/FluidAudioTests/Shared/ModelHubOfflineTests.swift).

FluidAudio reports about 120x to 190x real-time processing on an M4 Pro in its current documentation. Still must treat those numbers as upstream claims until its own device matrix reproduces them.

## Important accuracy risks

Parakeet V3 and its Core ML exports need product-level safeguards.

FluidAudio issue [#760](https://github.com/FluidInference/FluidAudio/issues/760) demonstrated silent Ukrainian word corruption in the default palettized encoder. Pull request [#872](https://github.com/FluidInference/FluidAudio/pull/872) added an opt-in `int8-v2` encoder that fixed the supplied cuts, but the original encoder remains the default. Still should benchmark `int8-v2` and should not inherit FluidAudio's encoder default without evidence.

FluidAudio issue [#909](https://github.com/FluidInference/FluidAudio/issues/909) demonstrated complete blank outputs for certain audio cuts. The same failure reproduced in the full-precision MLX runtime, which indicates a Parakeet V3 model behavior rather than only a Core ML conversion defect. Pull request [#910](https://github.com/FluidInference/FluidAudio/pull/910) added a recovery ladder that retries speech-bearing blank windows with adjusted length declarations. It recovered 10 of 11 reproduced cuts and improved the reported long-file benchmark, but one cut remained unresolved.

This history also shows why `parakeet-mlx` is valuable. It can separate model behavior from Core ML conversion or windowing bugs and can act as an independent reference during regression work.

## Licensing and distribution

- `parakeet-mlx` source code uses Apache-2.0.
- FluidAudio source code uses Apache-2.0.
- The archived Swift MLX port uses MIT.
- The V3 model weights use CC-BY-4.0 in both the [MLX model repository](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) and the [FluidAudio Core ML repository](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml).

Still must preserve attribution for the model weights in the app's legal notices and release records. Legal review should confirm the exact attribution text before distribution.

## Recommended Still architecture

1. Use FluidAudio behind Still's own `TranscriptionEngine` interface.
2. Use Parakeet TDT 0.6B V3 for the final high-accuracy transcript.
3. Load model files only from Still's signed model store and enable FluidAudio offline mode before any loader runs.
4. Keep model selection automatic and invisible to the user.
5. Keep `parakeet-mlx` in a separate internal benchmark tool on Mac. Do not link it into the apps.
6. Do not use the archived Swift MLX port.
7. Treat FluidAudio's sliding-window V3 path as near-real-time until Still proves its two-second live-text target. FluidAudio distinguishes this path from true cache-aware streaming.
8. Keep a separate live-draft decision open. Parakeet EOU is true streaming but English-only, while Still requires English, Polish, Russian, Ukrainian, German, French, Spanish, and Italian.

## Acceptance experiment

The next implementation step should be a narrow native spike rather than full integration.

| Gate | Measurement |
|---|---|
| Platforms | Base M1 Mac, iPhone 13, current iPhone, and M-series iPad |
| Languages | EN, PL, RU, UK, DE, FR, ES, and IT |
| Inputs | Clean speech, real meetings, system-audio capture, accents, overlap, silence, and 60-minute recordings |
| Accuracy | WER by language plus named-entity errors and blank-window count |
| Responsiveness | Time to first draft, draft lag, final processing time, cancellation time |
| Resources | Peak RAM, sustained memory, energy impact, thermal state, and model storage |
| Reliability | Window seams, duplicate text, dropped text, interruption recovery, and background behavior |
| Privacy | Zero network attempts after the model pack is installed |

The spike should compare FluidAudio's default encoder with `int8-v2`. `parakeet-mlx` should produce the reference transcript for every disagreement. Still should lock the runtime and encoder precision only after the measured gates pass.
