# Still

Still is an offline-first meeting notebook for iPhone, iPad, and Mac. The first working slice records microphone audio, performs on-device speech recognition, and stores transcripts in a local SwiftData library.

## Privacy boundary

- Speech recognition requires an on-device recognizer and fails instead of falling back to a server.
- Meeting data lives in the app's local SwiftData store.
- The app has no account, analytics SDK, network client, or cloud entitlement.

## Run

```sh
xcodegen generate
open Still.xcodeproj
```

Use a physical device or a Mac with microphone access.

## Checks

`bin/check.sh` runs every check CI runs: the iOS build, the macOS unit tests, and the end-to-end suite. A green local run is enough; CI calls the same script.

```sh
bin/check.sh                   # everything
bin/e2e.sh                     # end-to-end only, on a fresh silent simulator
bin/e2e.sh --device <udid>     # a connected iPhone with UI Automation enabled
```

A Debug build hears `Still/DebugSupport/meeting.fixture.caf` instead of the microphone, so every run records the same meeting. Parakeet runs in the simulator too, so the suite checks the words it hears. The Model Pack is cached in `~/Library/Caches/Still-E2E/Models`, so only the first run downloads it. The selected language must support on-device speech recognition.

## Product path

The next slices are Mac system-audio capture, local summaries and semantic search, opt-in encrypted iCloud sync, and offline translation. Sync must stay off until the user explicitly enables it because enabling sync sends encrypted meeting data through iCloud.
