# Still — ticket progress

Repo: anq-no-one/still (gh account: anq-no-one). Branch: main. Commits land directly on main.

Verify gate:
    xcodegen generate
    xcodebuild build -project Still.xcodeproj -scheme Still-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
    xcodebuild test -project Still.xcodeproj -scheme Still-macOS -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

## Done
- #2 RecordingWorkflow seam — commit c53fa2f
- #3 CI workflow — commit 2307721
- #4 Parakeet inventory — commit 5180fee (device benchmarks still open, needs iPhone 13 + M1 hardware)
- #6 Encrypted Library — commit 21e4200
- #7 Chunked encrypted audio + recovery — commit f8972db (locked-screen capture unverified on device)
- #8 Model pack install — 6681e01
- #5 Pro entitlement seam + StoreKit config — 2d7d9ee
- #9 Live draft resilience — 74026c3 (2-second latency gates need device hardware)
- #10 Timestamped transcript, resumable final pass, segment playback — 9b72bb9

- #11 Mac system audio track — a3ac7e7 (ScreenCaptureKit path unverified without a live Mac session)
- #12 Menu bar + global shortcut — 97d096a

- #17 Grounded notes + templates — b4cf324 (local language model still absent; extractive generator is the shipped path)
- #18 Editing with preserved evidence — 7b8644c
- #19 Exact search — da09160 (semantic search needs an embedding model)
- #20 Export + encrypted archive — f2d0270

- #15 Track-based speaker groups + renaming — 03b4628 (no diarization model; groups stay generic)
- #16 Local translation beside the transcript — 8beabec (Apple Translation path unverified without device packs)

- #26 Private setup flow — 666fdac
- #21 Encrypted iCloud sync for text — f3e103f (needs iCloud entitlement + signing to run for real)

- #22 Resumable encrypted audio chunk sync — 778eb86
- #24 Recovery code + device revocation — d23a97b

- #23 Nearby pairing + direct transport — 03c0e6c (Network.framework path unverified without a second device)
- #25 Retention + recoverable deletion — 1b87606

- #13 Automatic recording for allowed apps — 3218e64
- #27 Siri / Shortcuts / Calendar intents — 3ed5bff

- #14 Safari extension + browser meeting bridge — 5032ab7
- #28 Opt-in diagnostics + network boundary test — 41d1e4c
- #29 Accessibility pass + string catalog — 9867316 (translation outstanding, needs a human)

- #31 Encryption/sync gate suite + security review — 9a11e91 (found and fixed two real bugs)
- #30 WER/DER harness + gate thresholds — b03d73d (no measurement taken; needs devices + fixtures + FluidAudio)

## Apple account (team R3XFQ7K885, holder anq.no.one@gmail.com)
Done via App Store Connect API:
- App ID com.andrii.still registered (ASC id 9N9NZB8VK9), UNIVERSAL
- Capabilities: ICLOUD (CloudKit, XCODE_6) and IN_APP_PURCHASE
- A MAC_OS device was registered, but with the IOPlatformUUID, which is the WRONG identifier.
  Xcode wants the provisioning UDID (System Information -> Hardware -> Provisioning UDID),
  which for this machine is 00006021-0010602C3ABB401E. Re-register that one, and disable the
  wrong entry. Archiving still worked; a plain signed Debug build of the Mac app does not.
- Signed archive + Mac App Store .pkg export verified end to end

ASC API key lives in 1Password item "colouring - App Store Connect API" (same team).
Key content is base64-encoded PEM: decode before use. Copy staged at
~/.appstoreconnect/private_keys/AuthKey_<id>.p8.

BLOCKED: POST /v1/apps returns 403 — Apple does not allow creating app records over the
API. Needs the App Store Connect web UI or a 2FA fastlane session.

## Smoke test on a simulator (first actual run of the app)
Found four defects the 182 unit tests could not: iOS product named Still-iOS.app, every sheet
carrying a Mac-shaped 420pt minimum width on a 393pt phone, setup steps floating mid-sheet, and a
keychain failure blaming the device for a missing entitlement. All fixed in ec07831.

Simulator entitlements come out empty and the signature ad-hoc, so keychain status -34018
(errSecMissingEntitlement) there is expected and is NOT proof of a product bug. Proving the
keychain path needs a properly provisioned build, which needs the provisioning UDID above.

Drive the simulator with: agent-device open --session sim --platform ios --device "iPhone 18 Pro"
com.andrii.still, then agent-device --session sim snapshot -i / tap @eN.

## Hard blockers (cannot be honestly finished here)
- #30 measurements: iPhone 13, base M1, locked evaluation set, FluidAudio linked
- #31 remainder: CloudKit capture from a provisioned container, Keychain on real hardware
- #32 TestFlight: Apple Developer team, signing, App Store Connect
- #33 App Store: submission and review
- #29 translation: professional translator for 11 languages
- #4 benchmarks: same hardware as #30

## Second gotcha
Twice now I committed before running the full gate and had to amend. Run BOTH schemes plus the
macOS test suite before every commit, not after.

## Gotcha
CKContainer.default() traps without the iCloud entitlement, and the macOS test host IS the app,
so anything touching CloudKit must resolve lazily. Always run the macOS test suite after touching
app startup.

## Cannot complete without hardware, accounts, or humans
#4 benchmarks, #30/#31 release gates, #32 TestFlight, #33 App Store launch,
#29 professional localization review, #13/#14 needing real call apps and browsers.

## Not authorized
Issues are not closed and no comments are posted; the user has not authorized GitHub mutations.

## Model cache
~/Library/Caches/Still/ModelCache/parakeet-tdt-0.6b-v3-coreml/<revision> (469 MB, verified digests)

## Wayfinder audit 2026-09-23
Gaps found against wayfinder.md and Capy 2.4.1 (id6667094162):
- A Diarization model (FluidAudio Sortformer <=4 / LS-EEND <=10) — speakers are track-based only
- B Semantic search (local embeddings, hybrid with exact) — exact only
- C Local LLM notes (Qwen by memory tier; topics, summary, actions with segment refs) — extractive only
- D Chromium extension + native messaging host on Mac — Safari only
- E UI localization 12 langs + store metadata locales — xcstrings empty, metadata en-US only
- F bin/release.sh reads wrong 1Password paths (vault is Personal; fields APP_STORE_KEY_ID / APP_STORE_ISSUER_ID / APP_STORE_KEY_CONTENT base64)
Deliberately not done: whisper.cpp (#4 made Parakeet primary), SQLite swap (SwiftData stores only sealed ciphertext), Pro gating (product chose free for now).
Blocked on user: App Store Connect app record for com.andrii.still does not exist (API cannot create; needs web UI login).
Plan: A,B,C,D in parallel worktrees, then E, then F, then TestFlight after the app record exists.

## Release push (from repo CLAUDE.md, 2026-09-23 evening)
Workstreams (agents in .claude/worktrees, merged into main one by one):
- W1 Diarization + speaker names (calendar attendees, voice profiles remembered across meetings)
- W2 Semantic search (NLContextualEmbedding, hybrid)
- W3 MLX local LLM: grounded notes, transcript cleanup pass, cross-recording facts and tasks on the strongest device
- W4 Mac MCP server exposing meetings, facts, tasks to codex/claude
- W5 Smart call capture on Mac (calls only, ignore YouTube/music) + Chromium extension
Then: W6 localization (main European languages), W7 ASO metadata + screenshots via Astro MCP (http://127.0.0.1:8089/mcp, works via curl JSON-RPC), W8 TestFlight (blocked: ASC app record missing).
Deployment target is now iOS/macOS 26.
- Site: public repo anq-no-one/still-app on GitHub Pages. https://anq-no-one.github.io/still-app/ (privacy/, support/). Source of the policy: docs/privacy-policy.md; regenerate the page when it changes.
- ASC app record: user creates it this once; next time do it in Chrome yourself.
- W9 Projects with colors: Mac chooses all / some / excluded projects per device, iPhone sees all, MCP exposes only the Mac's selection
- W10 Google Analytics (Firebase) + Crashlytics, opt-in only, Firebase project under Google account anq.no.one@gmail.com, set up in Chrome
- Diarization branch worktree-agent-a21221bbef762254b accepted (2 commits), follow-ups running; merge after the TestFlight trial build finishes
- ASC app record exists: "Still - AI note taker", Apple ID 6815369488
- TODO: semantic index builds on the main actor at unlock; move off main before release
