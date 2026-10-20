# TestFlight debug bundle

Debug and TestFlight builds show a ladybug **Debug Bundle** button in the Library toolbar, on each
recording, and as **Export Diagnostics (Zip with Audio)** in Settings › Diagnostics, where it replaces
the plain-text journal export. It zips what the device recorded (the last five recordings by default)
and offers Share (AirDrop, Mail) or Save to Files; the Mac app holds user-selected read-write access
for that save. The App Store build hides it; the channel comes from `AppTransaction.environment` at
run time (`BuildChannel.swift`), because TestFlight and the App Store ship the same binary. When
StoreKit cannot answer at launch the channel stays unknown: records are held in memory, nothing is
written or deleted, and the app asks again when it becomes active or Settings › Diagnostics opens.

## Contents

| File | What it holds |
| --- | --- |
| `device.json` | channel, version and build, OS, hardware, memory, model packs and their state |
| `library-summary.json` | shape of every recording (counts, flags), no content |
| `devlog.jsonl` | every developer-log record across launches (two rotating 24 MB files) |
| `performance.txt` | span percentiles (all launches and this launch), waits after input, worst main-thread hangs |
| `ai-trace.jsonl` | every on-device model call: system and user prompt, raw output, tokens, timing; note, title, speaker and memory decisions |
| `oslog-this-launch.txt` | the unified log for this process, frameworks included |
| `metrickit/` | MetricKit metric and diagnostic payloads (crash and hang call stacks) |
| `journal.txt` | the 90-day journal |
| `recordings/<day>-<id>/` | `audio-microphone.wav`, `audio-system.wav`, `tracks.json` (format, offset), `recording.json`, `transcript.txt`, `note.md`, and that recording's `ai-trace.jsonl` and `devlog.jsonl` |

## Record kinds in devlog.jsonl

- `span`: a timed piece of work. `thread` is where it started (`main` or `bg-<qos>`), `endThread`
  appears when it finished elsewhere, `cpuMS` is the thread's CPU time for synchronous spans.
- `interaction`: what a person waited for. `input.tap|click|key` runs from the hardware event to the
  frame commit after it; `queuedMS` is how long the event waited before the app saw it. Named
  interactions (`record.start`, `record.stop`, `open.recording`, `open.settings`, `search.type`,
  `title.regenerate`) add milestones such as `recording`, `listed`, `transcriptShown`.
- `hang`: the main thread did not answer a 100 ms ping. `blockedBy` lists the spans running on main.
- `sample`: every 5 s, process CPU %, memory footprint, threads, thermal state.
- `counter`: SwiftUI body evaluations per view in the last 5 s.
- `event`, `error`: lifecycle, journal mirror, MLX loads, transcription speed (`realtimeFactor`).

## Reading one

```sh
unzip Still-Debug-*.zip -d bundle && cd bundle/Still-Debug-*
less performance.txt
jq -c 'select(.kind=="hang")' devlog.jsonl | sort -t: -k2 -n | tail
jq -c 'select(.kind=="span" and .thread=="main" and .ms>16)' devlog.jsonl
jq -r 'select(.name=="mlx.generate") | .fields.output' ai-trace.jsonl
```

The WAV tracks are the exact PCM Parakeet saw, so `still-eval` can replay them.
