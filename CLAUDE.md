# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Still is

An offline-first meeting notebook for iPhone, iPad and Mac. It records audio, transcribes it on device with Parakeet (via the FluidAudio package), and keeps an encrypted local library. The product roadmap lives in `wayfinder.md` (Russian); ticket progress lives in `.claude/still-progress.md`.

## Commands

The Xcode project is generated. Edit `project.yml`, never `Still.xcodeproj/project.pbxproj`.

```sh
xcodegen generate                  # after adding/removing files or changing project.yml
bin/check.sh                       # full gate: iOS build, macOS unit tests, E2E (same script CI runs)
bin/check.sh --skip-e2e            # build + unit tests only
bin/e2e.sh                         # E2E on a fresh, muted, throwaway simulator
bin/e2e.sh --only testRecordTranscribeFindAndReopen
bin/e2e.sh --device <udid>         # physical iPhone with UI Automation enabled
bin/release.sh [ios|macos|both] [--upload]   # needs STILL_TEAM_ID; reads the ASC key from 1Password
```

Run a single unit test (Swift Testing, macOS host):

```sh
xcodebuild test -project Still.xcodeproj -scheme Still-macOS \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Still-shared \
  -only-testing StillTests/LibraryTests
```

- Unit tests run only on macOS (`StillTests` hosts in the Mac app). E2E runs only on iOS (`StillUITests`).
- Pass `CODE_SIGNING_ALLOWED=NO` (or `STILL_UNSIGNED=1` for `bin/check.sh`) when signing is unavailable. The local Mac build is signed on purpose, because iCloud and system audio capture need it.
- DerivedData is shared at `~/Library/Developer/Xcode/DerivedData/Still-shared` (override with `STILL_DERIVED_DATA`).
- Results land in `Artifacts/`: `check.log`, `E2E.log`, `*.xcresult`, `E2E-screens/`. Verify counts from the xcresult summary the scripts print, not from the exit code alone.
- CI (`.github/workflows/ci.yml`) just runs `bin/check.sh`. Run it locally instead of waiting on GitHub Actions.

## Workflow

- All work lands on `main`. No PRs. Temporary worktree branches get merged into `main` and deleted right away.
- Deployment target is iOS/macOS 26, Swift 6 strict concurrency.

## Architecture

### One source tree, two apps

`Still/` compiles into both `Still-iOS` and `Still-macOS`. Platform differences use `#if os(macOS)` inline. The Mac app also embeds `StillBrowserExtension` (Safari extension that reports browser meetings).

### Composition root

`Still/App/StillApp.swift` builds every concrete dependency and injects it: the SwiftData container, `Library`, `SyncEngine`, `RecordingCoordinator`, `LibraryNavigation`, App Intents environment, the Mac menu bar and global shortcut. Everything below it depends on protocols (`RecordingLibrary`, `AudioRecorder`, `TranscriptionSession`, `SyncTransport`, `EntitlementSource`, `DiagnosticsSink`, settings stores), and tests substitute fakes for them.

### Recording pipeline

1. `RecordingCoordinator` (Workflow/) owns the app-wide recording phase. The menu bar, shortcut, intents and `AutomaticRecording` all go through it.
2. `RecordingWorkflow` runs one capture: it starts the recorder and a `LiveTranscriber` draft, then saves or cancels.
3. Audio/ records microphone (and ScreenCaptureKit system audio on Mac) into encrypted chunks via `AudioChunkStore`, so a crash can be recovered.
4. Services/`FinalTranscription` runs the accurate Parakeet pass over captured tracks in windows, checkpointing progress so it resumes after interruption. `LiveMix` and `EchoFilter` merge mic and system tracks; tracks become speaker groups.
5. Notes/ builds notes extractively from the transcript. There is no local LLM yet.

### Storage and encryption

- `Library` (Storage/) is the single entry point to recordings. It must be unlocked first; `LibraryKeyRing` gets the key from the Keychain (`KeychainDeviceKeySource`), with a `RecoveryCode` as backup.
- SwiftData stores `EncryptedRecording`, whose `sealedContent` is a `RecordingContent` sealed by `LibraryCipher`. Titles, transcripts, segments and notes are never stored in plain text.
- Sync (Sync/) moves sealed recordings only. `SyncEngine` pushes/pulls `SyncChange` through a `SyncTransport` (`CloudKitSyncTransport` or `NearbySync` over the local network) and merges with `RecordingMerge`. Sync stays off until the user enables it.

### Privacy boundary is enforced by tests

`StillTests/NetworkBoundaryTests.swift` greps sources for network symbols (`URLSession`, `NWConnection`, `CKContainer`, StoreKit calls) and fails if they appear outside an allowlisted file. Adding network code means adding the file there with a reason. Speech recognition must stay on device and fail rather than fall back to a server. Model packs (Models/) download only after explicit user approval.

### Debug and E2E hooks

`Still/DebugSupport/` is compiled only in Debug; `*.fixture.caf` files are excluded from Release. `UITestLaunch` reads launch environment keys: `STILL_UI_TEST_RESET` wipes app data and Keychain, `STILL_AUDIO_FIXTURE` swaps the microphone for a bundled fixture, `STILL_MODEL_ROOT` points to a cached model pack. `bin/e2e.sh` caches the Parakeet pack in `~/Library/Caches/Still-E2E/Models`, enrolls Face ID and auto-approves it on the simulator, and deletes the simulator on exit.

## Docs

- `docs/release.md` — Apple account state and release steps
- `docs/release-gates.md` — audio and transcription quality thresholds
- `docs/security-review.md`, `docs/privacy-policy.md` — privacy claims the code must keep true
- `docs/models/`, `docs/research/` — Parakeet model notes
- `docs/localization.md` — supported languages, string catalog, accessibility
