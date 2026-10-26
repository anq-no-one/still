# Debug bundles and bug reports

Debug and TestFlight builds collect a developer log, hang stacks, crash notes and resource samples,
and offer **Report a Problem** (ladybug in the Library toolbar, on each recording, Settings ›
Diagnostics; on Mac also the menu bar and ⌃⌥⌘D; on iPhone and iPad a shake). The App Store build
collects none of it and deletes what a beta left; the channel comes from `AppTransaction.environment`
at run time (`BuildChannel.swift`), because TestFlight and the App Store ship the same binary. When
StoreKit cannot answer at launch the channel stays unknown: records are held in memory, nothing is
written or deleted, and the app asks again when it becomes active or Settings › Diagnostics opens.

## Report a Problem

- **What went wrong?** and attachments: photos, image files, or (Mac) a pasted screenshot.
- **Mark This Moment** keeps every thread's stack, the memory breakdown and `state.json` right
  now under `Developer/Markers/`, even if the report is sent later. Opening the sheet from the
  shortcut, menu bar or a shake marks the moment first; a main-thread hang over 2 s marks itself.
- **Save Debug Bundle** keeps the zip (Mac: `~/Downloads/Still Debug Bundles/`; iPhone/iPad: the
  app's own folder, listed in the sheet with Share), newest 10.
- **Submit Bug Report** sends it to the Mac that collects bug reports, through the tester's own
  private iCloud database (zone `BugReports`, records of the deployed `StillSyncChange` type),
  sealed with a key derived from the Library account key, in parts under 1 MB. A collecting Mac
  saves its own reports straight to the inbox.
- **Collect bug reports on this Mac** (on by default in Debug builds, a toggle in TestFlight):
  checks iCloud at launch and every 5 minutes, writes each report to
  `~/Downloads/Still Bug Reports/<date>-<device>-<id>.zip`, then deletes it from iCloud.
- After a crash or a launch that found the previous session still open, the Library offers a banner
  to report it.

## Contents

| File | What it holds |
| --- | --- |
| `summary.md` | start here: tester note and attachments, marked moments with ±30 s of log, crashes and abrupt endings, worst hangs, memory peak and leaks, CPU, audio gaps per recording and track, sync failures by CloudKit code, errors by name, and which source folder each kind of record comes from |
| `note.txt`, `attachments/` | what the tester wrote and showed |
| `markers/<stamp>/` | each marked moment: `marker.json`, `threads.txt`, `memory.json`, `state.json` |
| `device.json` | channel, version and build, OS, hardware, memory, model packs and their state |
| `state.json` | each subsystem now: recording phase, library, sync (last failure, devices), models, permissions, automatic recording, AI tools, microphone |
| `library-summary.json` | shape of every recording (counts, flags), no content |
| `devlog.jsonl` | every developer-log record across launches (two rotating 24 MB files) |
| `performance.txt` | span percentiles (all launches and this launch), waits after input, worst main-thread hangs |
| `threads.txt` | every thread's name, CPU and call stack when the bundle was made |
| `images.json` | loaded binaries with UUID and load address, for `atos` |
| `memory.json` | memory breakdown, MLX memory, live objects per type, per-thread CPU |
| `crashes/<stamp>/` | what a crashed launch left: `crash.txt`, `crash.json` (signal or exception, stack), that launch's `images.json` |
| `ai-trace.jsonl` | every on-device model call: system and user prompt, raw output, tokens, timing; note, title, speaker and memory decisions |
| `oslog-this-launch.txt` | the unified log for this process, frameworks included |
| `metrickit/` | MetricKit metric and diagnostic payloads (crash and hang call stacks, exit reasons) |
| `journal.txt` | the 90-day journal |
| `recordings/<day>-<id>/` | `audio-microphone.wav`, `audio-system.wav`, `tracks.json` (format, offset), `recording.json`, `transcript.txt`, `note.md`, and that recording's `ai-trace.jsonl` and `devlog.jsonl` |

## Record kinds in devlog.jsonl

- `span`: a timed piece of work. `thread` is where it started (`main` or `bg-<qos>`), `endThread`
  appears when it finished elsewhere, `cpuMS` is the thread's CPU time for synchronous spans.
- `interaction`: what a person waited for. `input.tap|click|key` runs from the hardware event to the
  frame commit after it; `queuedMS` is how long the event waited before the app saw it. Named
  interactions (`record.start`, `record.stop`, `open.recording`, `open.settings`, `search.type`,
  `title.regenerate`) add milestones such as `recording`, `listed`, `transcriptShown`.
- `hang`: the main thread did not answer a 100 ms ping. `blockedBy` lists the spans running on main;
  from 250 ms main's stack is sampled every 100 ms: `stack` (heaviest sample), `stackSamples`,
  `stackProfile` (frames shared by most samples).
- `sample` (`resources`, every 5 s): CPU %, `topThreads`, footprint, peak, internal, compressed,
  resident, malloc, available (iOS), MLX active/cache/peak, `executorMS.<priority>` (wait for a
  cooperative-pool thread), thermal state.
- `counter`: `renders` (SwiftUI body evaluations per view) and `liveObjects` (instances per type).
- `event`, `error`: lifecycle, journal mirror, MLX and Parakeet loads, transcription speed, and per
  subsystem: `audio.*` (`audio.stats` every 5 s per track with level, gaps, stalls, drops; devices,
  route, configuration changes, stream stops), `call.*` and `browser.*` (every auto-record
  decision and why), `sync.*` (`sync.run` with counts per step, `sync.cloudKit.*` with real CKError
  codes and per-record failures, `sync.audio.*`, `sync.nearby.state`), `model.*`, `mcp.*`,
  `memory.pressure`, `crash.previous`, `user.marker`, `bugReport.*`. Records made during a capture
  carry `recordingID`.

## Triage a bundle with Claude

```sh
bin/bug-reports.sh                 # reports collected on this Mac that are not handled yet
bin/bug-reports.sh open latest     # unpack, symbolicate, print summary.md and attachment paths
bin/bug-reports.sh done <name|all> # mark handled (Artifacts/BugReports/processed.txt)
bin/debug-bundle.sh <zip|folder>   # the same for any bundle, e.g. one AirDropped into Downloads
```

Bundles unpack into `Artifacts/DebugBundles/<name>/`. Symbolication matches `images.json` UUIDs
against dSYMs in `~/Library/Developer/Xcode/Archives/Still-dSYMs/` (TestFlight, kept by the
Fastfile) and binaries in the shared DerivedData products (Debug), and writes
`symbolicated/threads.txt`, `hangs.txt`, `crashes.txt` and `marker-*-threads.txt`. System
frames stay as image + offset.

Reading order for an agent: `summary.md` → `note.txt` and `attachments/` (look at the images) →
the marked moment's folder → `symbolicated/` → the matching `recordings/<id>/devlog.jsonl` → the
source folder `summary.md` names. Useful queries:

```sh
jq -c 'select(.kind=="hang")' devlog.jsonl | sort -t: -k2 -n | tail
jq -c 'select(.name=="audio.stats" and ((.fields.gaps|tonumber) > 0 or (.fields.dropped|tonumber) > 0))' devlog.jsonl
jq -c 'select(.name|startswith("sync.")) | select(.kind=="error" or .fields.failed != null)' devlog.jsonl
jq -c 'select(.kind=="sample") | [.at, .fields.footprintMB, .fields.cpuPercent, .fields.topThreads]' devlog.jsonl
jq -r 'select(.name=="mlx.generate") | .fields.output' ai-trace.jsonl
```

The WAV tracks are the exact PCM Parakeet saw, so `still-eval` can replay them.
