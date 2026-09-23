# Still privacy policy

Last updated: 23 September 2026

## The short version

Still does not collect your data. There is no account, no analytics, and no server that sees your
recordings. What you record stays on your device unless you explicitly turn on synchronization,
and even then it travels and rests as ciphertext your own devices can open.

## What Still stores, and where

Recordings, transcripts, notes, facts and tasks, speaker names and voice profiles live in an encrypted Library on your device.
Audio is written in encrypted pieces as you record. The encryption key is held in the device
keychain and released by Face ID, Touch ID or your device passcode.

Still never uploads this content anywhere on its own.

## When Still uses the network

Still makes no network request in normal use. It reaches the network only when one of these
happens, and only for that purpose:

| You do this | What travels |
|---|---|
| Approve the model download | A request to the model host for the transcription, speaker and language model files. No content of yours is sent. |
| Turn on iCloud sync | Encrypted recordings to your own iCloud account. Apple stores ciphertext; it cannot read your transcripts, notes, audio, or key. |
| Turn on nearby sync and pair a device | The same encrypted data, directly to the device you paired, over your local network. |
| Buy or restore Still Pro | A purchase request to Apple. Apple tells us whether you own the product, nothing else. |
| Share or export | Only what you chose, only to where you chose, through the system share sheet. |
| Turn on diagnostics | The name of what failed, the app version, and whether you are on a Mac or an iPhone. No audio, transcript, note, search, or key. |

Diagnostics is off unless you turn it on, and you can turn it off again at any time.

## Voice profiles

When you name a speaker, Still keeps a voice profile so it can recognize that person in later
recordings. The profile is a numeric voice signature, not audio. It is stored and synced encrypted
like the rest of your Library, and you can delete it at any time.

## Local AI

Summaries, tasks, facts, transcript cleanup and search run on your own devices. When you own several
devices, the most capable one does the heavy work and syncs the results, encrypted, to the others.
No text or audio is sent to an AI service.

## Access for AI tools on your Mac

If you turn on "Allow AI tools to read meetings" on your Mac, local tools you configure, such as
Claude Code or Codex, can read your meetings through a connection that stays on that Mac. It is off
by default, works only while your Library is unlocked, and you can revoke it at any time. What
those tools do with the data afterwards is governed by their own privacy terms.

## The browser extensions

The optional Still extensions for Safari and Chromium browsers report that a meeting started or ended on a site you allowed. It
reads no page content, and nothing from your Library ever reaches the browser.

## Permissions Still asks for

- **Microphone** — to record. Still cannot record without it.
- **Speech recognition** — to turn speech into text on your device.
- **Screen recording (Mac)** — to capture what a call is playing. Still takes audio only; no
  screen image is captured or stored.
- **Calendar** — optional, to suggest a title and the people expected in a meeting.
- **Local network** — optional, only for syncing directly with your own nearby devices.

You can refuse or withdraw any of these in system settings. Refusing one limits that feature and
nothing else.

## Deleting your data

Deleting a recording removes it from your Library and from the devices you sync with. It stays
restorable for thirty days, then Still removes the record and its audio permanently. You can also
set audio to be deleted automatically after 30, 90 or 365 days while keeping the text.

Deleting the app removes the local Library with it. If you used iCloud sync, sign out of sync
before deleting the app, or remove Still's data from your iCloud account afterwards.

## What Still cannot protect against

- **Metadata is not encrypted.** When a recording was made and how long it lasted are stored and
  synced in the clear. Someone with access to your iCloud records learns when you recorded, never
  what was said.
- **Your recovery code is the whole key.** Anyone holding it can open your Library, and losing it
  with no unlocked device means the Library cannot be opened. There is no back door.
- **A compromised device.** Still relies on the keychain and biometric enforcement; no app can
  restore that boundary once the operating system itself is compromised.

## Recording other people

Recording law differs by country and state. Still always shows when it is recording and lets you
stop at once, but obtaining any consent the law requires is your responsibility.

## Contact

Questions about this policy: anq.no.one@gmail.com
