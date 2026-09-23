# Still product specification — meeting memory, capture, and trust

## Problem Statement

People leave meetings with recordings but still lose decisions, commitments, and their sources. A person working on several projects needs a reliable account of what changed without leaking one project's meetings onto another work Mac. The app must make recording simple, keep processing local, explain its permissions, and make failures diagnosable without exposing meeting content.

## Solution

Still is a native meeting memory for iPhone, iPad, and Mac. It captures or imports audio, shows a clearly labelled live draft, then runs a more accurate local final pass. The first post-meeting view presents decisions and proposed tasks linked to the exact transcript segment and audio time. Each project keeps a sourced history of facts and changing decisions. A Mac stores and processes only its selected projects; an iPhone can hold all projects. An approved local tool can read sourced text from the projects available on that Mac.

The first public release includes the complete agreed product, not a paid subset or an early-access feature gate. Every function is free while monetization remains undecided. The visual reference is the ten VoiceInk CleanShot images on the user's Desktop from 2026-09-24 00.16.31 through 00.16.48. They inform navigation density and settings layout, not Still's identity or wording.

## User Stories

1. As a new user, I want a dedicated, polished introduction, so that I understand Still before it requests access.
2. As a new user, I want an explanation before each system prompt, so that I know why access is needed and what a refusal changes.
3. As a new user, I want Record to appear only when this device has the permissions and local model needed to record, so that the first attempt works.
4. As a user who declines Calendar or meeting-window access, I want recording to remain usable, so that optional context does not become a condition for recording.
5. As a user, I want an optional app lock, so that I can choose between fast entry and an extra identity check.
6. As a Mac user, I want Still to recognize an allowed meeting and retain its start, so that I do not have to watch for the exact moment to press Record.
7. As a Mac user, I want a false meeting trigger discarded, so that a microphone test does not become a saved recording.
8. As a participant, I want a visible recording indicator and stop control, so that capture is never hidden from me.
9. As a participant, I want a labelled live draft, so that I can follow the meeting without mistaking it for the final record.
10. As a participant, I want a more accurate final transcript with timestamps, so that I can check what was said.
11. As a participant, I want each speaker separated and uncertain names shown as suggestions, so that Still does not silently assign a wrong person.
12. As a participant, I want to approve a remembered voice profile separately, so that a single correction does not create lasting biometric recognition without consent.
13. As a user, I want decisions and proposed tasks first after a meeting, so that I can act without reading the entire transcript.
14. As a user, I want every extracted statement to open its source segment and audio time, so that I can verify it.
15. As a user, I want to confirm or edit proposed tasks, so that the project list contains commitments I trust.
16. As a project member, I want prior and current decisions shown with dates and sources, so that I can see how an agreement changed.
17. As a user of several work Macs, I want to confirm a recording's project before cross-device transfer, so that a wrong guess cannot send it to another job's Mac.
18. As an iPhone user, I want all my projects in one library, so that I can review them without changing devices.
19. As a Mac user, I want only selected projects stored and processed locally, so that unrelated work is absent from that machine.
20. As a user, I want exact and semantic search to open the matching moment of audio, so that I can find evidence quickly.
21. As a user, I want to import audio or video from Files or drag and drop, so that a meeting recorded elsewhere receives the same local treatment.
22. As a user, I want the extracted encrypted audio kept without copying the source video, so that the library avoids unnecessary storage.
23. As a project member, I want a project vocabulary for names and specialized terms, so that future transcripts use the right words.
24. As a user, I want to request reprocessing of an old recording after changing its vocabulary, so that manual corrections are not overwritten.
25. As a Mac user, I want the system microphone by default and an explicit device picker with a level test, so that I can fix the wrong input before a call.
26. As a keyboard user, I want configurable start and stop shortcuts with conflict feedback, so that capture works from other apps.
27. As a user, I want to see installed model packs, sizes, languages, and offline readiness, so that I can manage storage without choosing an inference engine.
28. As a user, I want a hint about other audio during a meeting, so that I can decide whether to pause it myself.
29. As a Mac user, I want optional launch at login while Still remains in the Dock and menu bar, so that I can choose when it is available.
30. As a user, I want to move vocabulary and ordinary preferences between devices without transferring secrets or permissions.
31. As a user, I want a dashboard of unsorted recordings, proposed tasks, and changed decisions, so that it shows work to resolve rather than vanity statistics.
32. As a user, I want a text export of the local action and error log with recent breadcrumbs, so that a failure can be reproduced.
33. As a user, I want logs to exclude speech, names, project titles, paths, prompts, and keys, so that debugging does not disclose meeting content.
34. As a user who enabled app lock, I want an active recording to continue when the interface locks, so that a meeting is not cut off.
35. As a user of a local assistant, I want separately approved, read-only access to sourced text in this Mac's projects, so that its answer can be checked.

## Implementation Decisions

- The canonical concepts are Meeting, Recording, Project, Transcript Segment, Speaker Suggestion, Proposed Task, Extracted Fact, User-Confirmed Fact, and Source. A source identifies a recording segment and time. Model validation checks source existence and transcript support; it does not turn an extracted fact into user confirmation. A local tool may read a model-validated fact only with an explicit automatically-extracted status and source.
- A short in-memory capture buffer begins when an allowed call app uses the microphone. Still saves it only after a meeting signal is established and discards it otherwise. Manual capture remains available. Allowed apps and sites, recording state, and stop control remain explicit. When a browser call and media play together, Still retains the mixed audio and marks the uncertain interval; system capture cannot promise tab-level isolation.
- The live transcript is a draft. The accurate local final pass replaces it. Notes, facts, and tasks derive from the final transcript. If final processing fails, encrypted audio remains available for retry. The app selects models by device, language, memory, and recording length. The user manages model downloads and storage, not model tuning or a cloud provider.
- Speaker naming combines diarization, Calendar context, app or browser accessibility information, and transient analysis of the call window. Frames are processed in memory and never retained or synced. Name and active-speaker signals are aligned with audio time. Uncertain identity remains a suggestion requiring confirmation. A reusable voice profile requires separate consent.
- Still proposes a project from context but holds a newly captured or imported recording on the source device until the user confirms its project. Per-device project selection governs the local copy, local processing, and local tool access. Project-scoped key distribution must enforce this when iCloud contains records from all projects. The strongest available device processes only the projects it is allowed to hold; the iPhone processes remaining projects locally if necessary.
- Project memory preserves the history of decisions and contradictions. Proposed tasks remain drafts until reviewed. Every generated statement links to existing source segments. User edits and original evidence survive reprocessing and synchronization.
- Each local tool client receives separate user approval and read-only access. It can retrieve search results, facts, tasks, and transcript passages with times and verification status from this Mac's selected projects. It cannot receive audio, transient screen images, or unreviewed task drafts, and cannot edit the library.
- The main Mac interface uses a work-oriented dashboard and a spacious, native sidebar settings window. Settings cover capture, audio input, project vocabulary, model downloads, shortcuts, projects and sync, security, diagnostics, and appearance. iPhone and iPad adapt navigation to their space. Still selects meeting, lecture, interview, or voice-note structure automatically; the user may change it after processing. The visual system follows Apple Human Interface Guidelines, uses native controls, supports dark mode, VoiceOver, Dynamic Type, keyboard navigation, and reduced motion, and retains an original Still identity.
- File import is available on all supported platforms through the platform's document picker or share flow, plus drag and drop where appropriate. The source audio or extracted video audio joins the same encrypted processing path as capture. Still retains encrypted audio and source metadata, not a duplicate video. Import shows progress, cancellation, unsupported-format and insufficient-space failures, and a retry without duplicate recordings.
- A project vocabulary stores proper names, terms, and spelling variants. New processing uses it. Old recordings are reprocessed only after an explicit request; manual transcript edits are never replaced. The original audio remains the evidence.
- Mac audio input follows the system default unless the user chooses another device. Settings show the active device and input level, and clearly report a fallback when hardware disappears. Global shortcuts for start and stop are configurable and reject collisions. Still can suggest that other media is interfering, but does not pause another app. Launch at login is opt-in. The Dock icon and menu bar control remain visible.
- Selective settings export includes vocabulary, shortcuts, and ordinary preferences. It excludes keys, recovery material, analytics and diagnostics consent, project availability, and local tool approvals, which are established separately on the destination device.
- First launch uses a dedicated, polished, interactive onboarding flow. Each permission gets a contextual explanation before the system sheet. Microphone and Mac system audio are required before Record is shown; recommended local model readiness is also established. Calendar and window analysis are offered with an explicit degraded path when declined. iCloud, analytics, and diagnostics are separately optional. An interrupted setup resumes without repeating completed steps.
- Library encryption remains in place. A separate app-lock option is off by default. When enabled, it authenticates at a fresh launch and after five minutes away from the app by default, with a configurable delay and system credential fallback. It does not interrupt recording or background processing; returning to the library requires authentication while stop remains available.
- A single local event journal records typed user actions, state transitions, outcomes, and errors with time, app version, error code, and correlation identifiers. It never records keystrokes or user content. A failure includes the preceding 100 safe event names as breadcrumbs. The journal is protected at rest using a device-local key independent of library unlock, so unlock failures can be recorded. It retains 90 days, shows storage use, and exports every retained event as a potentially large plain-text file using streaming output. Export is an explicit user action. There is no automatic log upload.
- Google Analytics and Crashlytics remain off by default and require separate consent. Their payloads exclude meeting content, names, project titles, queries, and keys. Model download and opt-in encrypted iCloud or nearby sync are the other permitted network paths. Local use remains fully functional offline after model installation.
- Shared domain rules remain behind small interfaces at the recording coordinator and library seams. Capture and import feed one processing path. Diagnostic event construction is centralized. Recording, import, sync, and app-lock state transitions should make invalid combinations unrepresentable where practical, report failures, and preserve recoverable data. The aim is to prevent classes of bugs with clear ownership and tests; no design can guarantee that bugs are impossible.
- The planned deployment minimum is iOS and iPadOS 18 and macOS 15, subject to proving that every promised path works there. Current project settings target version 26. Full functionality is a public-release gate. All functions remain free; monetization is deferred.

## Testing Decisions

- Test observable behavior at the highest existing seams, using the recording coordinator and library for capture or import through project assignment, final transcript, sourced note, sync eligibility, and local tool retrieval. Keep narrow tests for policy and error cases rather than mirroring implementation details.
- Run a first-launch UI path that explains each permission, covers refusal and later grant, reaches Record only when required capture is ready, and resumes after interruption. Check the optional Calendar and window-analysis paths independently.
- Run a file-import path through project vocabulary, final processing, library search, and sourced result. Cover unsupported and corrupt files, cancellation, insufficient space, duplicate retry, and preservation of manual edits during explicit reprocessing.
- Run an app-lock path that continues capture while the library is hidden, permits stop, unlocks with the system fallback, and does not repeatedly prompt during continuous use.
- Force a processing and sync failure, export the complete retained text log with breadcrumbs, and verify that no injected transcript, name, project title, file path, prompt, or key appears. Cover the 90-day boundary and large streaming exports.
- Verify project isolation with at least two Macs and one iPhone: an unconfirmed recording never reaches a Mac, removal of a project removes its local access, and a local tool cannot read another project's text. Verify encryption and interrupted sync with existing security gates.
- Measure live and final transcript latency, WER, diarization DER, memory, and long-recording throughput on the minimum supported devices against the locked release fixtures. Test real Zoom, Teams, and Meet calls, mixed browser media, and transient speaker evidence rather than inferring their behavior from mocks.
- Verify Mac, iPhone, and iPad layouts against Apple Human Interface Guidelines with VoiceOver, Dynamic Type, keyboard navigation, dark mode, reduced motion, and all target localizations. Retain visual evidence outside source directories.

## Out of Scope

- Pricing, paid tiers, subscriptions, license screens, and StoreKit gating of product capabilities.
- Cloud speech or language-model inference, arbitrary model selection, BYOK, and automatic control of other apps' media.
- Retaining imported video or meeting-window frames, automatic upload of text logs, and transferring secrets or consent through a settings backup.
- Public meeting links, collaborative editing, and write access through the local tool interface.

## Further Notes

- This specification supersedes conflicting product choices in the original umbrella issue and older Wayfinder sections, notably paid Pro gating, manual model selection, and exclusion of speaker identity suggestions. It does not declare older completed issue work invalid; new work should reuse it.
- The main branch already contains encrypted storage, recording, live and final transcription, exact and semantic search, sync structure, export, onboarding, and diagnostic foundations. Existing worktrees contain unfinished speaker, project, browser, local-model, and local-tool work. Inspect their diffs before implementing any overlapping item; do not discard their changes.
- Current documentation and progress notes contain historical snapshots, including an obsolete claim that the App Store Connect app record does not exist. Verify current external state before release work.
- Publish this specification as one English GitHub issue in `anq-no-one/still`, linked to umbrella issue #1, with the existing `ready-for-agent` label. Keep the new work in as few coherent implementation PRs as practical; do not create process-only PRs.
