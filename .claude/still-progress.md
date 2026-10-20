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
- Done: semantic index builds in the background after unlock (2026-09-25)

## Product specification and issue handoff — 2026-09-24

- Canonical current product scope: `docs/still-product-spec.md`; published as GitHub issue #34. Treat `docs/wayfinder.md` and issue #1 as historical context where they conflict with #34.
- Still is a free, complete public app with no Pro tier, subscription, purchase gate, or default account requirement. iOS/iPadOS and macOS 26 are the current deployment targets in this worktree.
- First run must explain each required permission before the system prompt and withhold Record until required capture access and the local transcription pack are ready. Calendar and meeting-window access are optional. App lock is separately opt-in and off by default.
- The privacy boundary is local-first. Recording content stays encrypted; no AI-provider upload. Unconfirmed project assignment blocks sync. A Mac must receive only selected projects and their keys, not merely hide excluded projects in its UI. Remembered speaker voice profiles require separate consent.
- Diagnostics need a local 90-day event journal, safe 100-event breadcrumbs on failures, complete redaction of user content and secrets, and a streaming plain-text export without a file-size cap.
- Settings should follow native Apple patterns with a spacious Mac sidebar and adaptive iPhone/iPad layout. The attached CleanShot references informed layout ideas, not a pixel copy. Model selection stays automatic. Preference export must exclude keys, consents, device access, and tool grants.
- GitHub work items #35–#54 are the agent-sized implementation slices under #34. Each contains a bounded outcome, acceptance checks, verification command, and `Blocked by` edges. Start with an unblocked issue, finish and verify it, then move to its dependent issue; do not pick a blocked issue simply because it has `ready-for-agent`.
- First slices: #35 onboarding, #36 optional lock, #37 diagnostic journal, #38 Mac audio import, #39 timed speaker suggestion, #40 approved Mac capture, #41 project confirmation, #44 microphone selection. Dependencies include #41 -> #47 -> #42/#43/#45/#46, #43 -> #48, #45 -> #49, #44 -> #50, #38 -> #51, #42 -> #52, #37 -> #53, and #39 -> #54.
- Existing #29, #32, and #33 now use the free-product release criteria. #8 and #9 had stray CLI output at the top of their bodies; it was removed. #9 no longer depends on the closed Pro issue #5. No issue was closed because the remaining open tasks still describe work to do; #1 was left as the historical parent per the ticketing contract.
- This handoff added documentation and edited GitHub issues only. Do not infer any new app-code implementation from it. At handoff, `main` is at `c8acffd` and no task-owned background job is running. Another worker committed the spec, progress notes, fixture, and wayfinder move while this issue pass was in progress; preserve that commit and all existing `.claude/worktrees/` content.
- Exact next action for the implementer: open #35, inspect the current onboarding/model-permission flow and any active worktree, then implement only its acceptance criteria and run its listed verification command.

## Ralph loop on #34 — 2026-09-24
- Merged into main: speaker separation + owner name (a21221), projects + project UI (a0e0), per-app call capture + Chromium native host (a19f), MCP server + still-mcp helper (a5c1). Worktrees and branches removed. 361 unit tests green.
- still-mcp cannot run from the sandboxed unit-test host (SIGTRAP in sandbox init), so bin/check.sh smoke-tests it instead.
- Remaining worktree: agent-a7189 (MLX notes WIP: JSONSchema, TranscriptChunker) — use for #43.
- Next: #35 onboarding, then #36, #37, #38, #39, #40, #41, #44 (unblocked).
- Done on main (local, not pushed yet): #35 setup resume/access pane/a11y, #36 app lock, #37 journal (sealed with device Keychain key), #41 project confirmation gates sync, #40 automatic capture keeps only meeting-like calls, #53 journal covers record/sync/export/delete/confirm.
- E2E testRecordTranscribeFindAndReopen fails since the worktree merges (6feccd6 passes, 8aaf3ce fails: toolbar Record hit point -1,-1, live transcript never shows "budget"). Bisecting in .claude/worktrees/baseline-e2e with DerivedData Still-baseline. Do not push main until E2E is green.
- Agents running in worktrees: #38 Mac audio import, #44 Mac microphone choice, #39 speaker cues from Meet. Merge each, run gate.
- Found: no UI to join a second device (each device has its own master key; restore(using:) has no caller), so cross-device sync cannot open payloads today. #47 must add device joining + per-project keys (HPKE grants to device public keys).
- Found: voice profiles match voices across meetings without consent (merged diarization work). Gate behind opt-in in #54.
- 2026-09-24 morning: on main and pushed — #38 import, #44 mic choice, #39 Meet speaker cues, #54 voice consent, #50 shortcut/login/media hint, #40 browser mixed-media spans, #47 per-project keys + device joining (HPKE grants, 9-digit code), interrupted-processing recovery fix, 10-language UI translation (bin/localize.py), E2E onboarding fix (2/2 green). Privacy page on anq-no-one/still-app regenerated (scratchpad policy_html.py converter).
- Running agents: #51 video/share import, #43 extraction (MLX + fallback), #45 settings sidebar, #42 vocabulary, translator for 26 #47 strings.
- Next: #46 (after #43), #48 (after #43), #49 (after #45), #52 (after #42). Then Firebase opt-in analytics/Crashlytics (spec, no slice issue yet), release #30/#32/#33.
- Open security gaps from #47: join code lacks commit step (MITM by iCloud controller could brute-force 1e9 codes); revoke rotates only account key, not project keys.
- 2026-09-24 evening: merged #42 vocabulary, #43 extraction (Qwen3 MLX packs, extractive fallback), #45 settings sidebar, #46 MCP per-client approval + list_facts/list_tasks, #51 video/share import, #52 apply vocabulary with review, speaker-name opt-in, revoke renews project keys, join code PBKDF2. still-eval WER/hour measurements in docs/release-gates.md. 404 strings in 10 languages. main green: 546 unit, E2E 3/3.
- Running: #48 dashboard (opus), #49 preference export (sonnet).
- After them: all #35–#54 slices done → release work #29 (a11y pass), #30 (devices), #32 TestFlight, #33 launch; Firebase opt-in needs user OK.
- 2026-09-25: all slices #35–#54 implemented on main (pushed b72655a): +#48 dashboard/decision history, #49 preference transfer, accessibility audit E2E (setup, library, settings, access pass), accent/record colors meet contrast. main: 572 unit, E2E 4/4, 429 strings × 10 languages.
- Blocked on user: 1Password CLI not configured ("No accounts configured") → no ASC key → no TestFlight (#32). Firebase project creation needs explicit OK. GitHub issues not closed (needs OK).
- Not verifiable here: iPhone 13 / base M1 measurements (#30), native-speaker review (#29), real Zoom/Teams/Meet calls (#39/#40).

## Names, titles, background — 2026-10-08 (spec #72, tickets #73–#78)
- Done on main: #78 Dock Quit / Cmd+Q hide to menu bar (BackgroundPresence, QuitOrigin), launch at login on after setup; #73 titles via Apple on-device model → MLX → calendar title → key-sentence fallback, titleSource automatic/user; #75 Regenerate Title + background retitle (UserDefaultsRetitleLedger per tier); #74 GuestNaming: NLTagger vocatives/self-intros + cue agreement, journal `speakersNamed` counts; #76 Meet roster (`participants` phase, extension 1.1) and roster elimination.
- Chrome extension is loaded unpacked from Artifacts/ChromiumExtension: reload it in chrome://extensions after `bin/chromium-extension.sh`.
- Meet active-speaker selectors are obfuscated classes and unverified on a live call; roster + spoken names do not depend on them.
- Uncommitted WIP in main checkout (detail perf: AudioChunkStore, RecordingPlayer, Library, RecordingDetailView, two tests) is not from this pass; it was preserved, not committed.
- Release: env APP_STORE_* key reaches app 6815369488 (anq.no.one team R3XFQ7K885); pass it as STILL_OP_* when 1Password does not answer.

## TestFlight debug bundle — 2026-10-19
- Debug/TestFlight builds (channel from AppTransaction, `BuildChannel.swift`) keep a sealed developer log and AI trace (`Still/Diagnostics/DevLog.swift`, `AITrace.swift`), spans with thread/CPU (`Perf.swift`), input→frame waits, main-thread hang watchdog, 5 s CPU/memory samples, render counters (`Responsiveness.swift`), MetricKit payloads. App Store channel deletes all of it.
- Ladybug "Debug Bundle" button (Library toolbar, recording detail, Settings › Diagnostics) zips logs, performance.txt, OSLog of this launch, and per recording WAV tracks, recording.json, transcript.txt, note.md, ai-trace. Layout and jq recipes: `docs/debug-bundle.md`.
- Spotted while instrumenting, not fixed yet (wait for bundle data): `SemanticIndex.update` re-embeds every segment on main on each `Library.write` (every edit and memory chunk); `RecordingDetailView.refreshKey` includes `updatedAt`, so every save reloads the transcript; `MemoryExtraction` and `Library` writes run on main.
- `testPrimaryScreensPassTheAccessibilityAudit` is flaky on the iOS 27.0 simulator runtime: fails on baseline main too (contrast on "Add" in detail), passes alone.
- dSYMs of every TestFlight build are copied to `~/Library/Developer/Xcode/Archives/Still-dSYMs/<scheme>-<version>-<build>` by the Fastfile.

## Feedback 2026-10-20 (Obsidian still_development)
- Saving an export failed on Mac ("don't have permission to access <folder>"): the sandbox held only `files.user-selected.read-only`; now read-write (`project.yml`, `Still-macOS.entitlements`, `MacEntitlementsTests`).
- Project colors showed black in Mac menus: menus template SF Symbols, so swatches are drawn bitmaps (`ProjectSwatch`, `ProjectColor.swatch`).
- Settings › Diagnostics in TestFlight now exports the zip with audio instead of the text journal; an unknown build channel no longer deletes the log and is retried.
- Still open from `bugs 19 oct report.md`: titles from location address, generated summary with who said what, owners on decisions/action items, remove Proposed Tasks, speakers UI (hide merge, spacing), Teams speaker names, freeze while scrolling a long note.
