# Localization and accessibility

## Supported interface languages

English (source), Polish, Ukrainian, Russian, German, French, Spanish, Italian, Japanese, Korean,
Simplified Chinese, Traditional Chinese.

`Still/Supporting/Localizable.xcstrings` is the string catalog. `SWIFT_EMIT_LOC_STRINGS` is on, so
every `String(localized:)` and every SwiftUI text literal is extracted into it on build.

## What is done

- All user-facing text is a literal SwiftUI string or `String(localized:)`, so it extracts rather
  than being built by string interpolation from fragments.
- The catalog is in place with English as the source language.

## What is not done

**No language other than English has been translated.** Privacy wording, permission explanations,
and recording-state text decide whether a user understands where their audio goes, so these need a
professional translator, not machine output. Until that review lands, shipping a localized build
would claim a guarantee Still cannot back.

The remaining localization gates are also outstanding: truncation at the longest translations,
bidirectional-safe rendering, pluralization, and localized App Store metadata and screenshots.

## Accessibility

Done:

- Reduced Motion turns off the recording pulse on both the capture sheet and the Library toolbar.
- The recording indicator, elapsed time, speaker name fields, transcript segments, and note items
  carry VoiceOver labels and hints that say what selecting them does.
- Type scales with Dynamic Type; the large recording glyph scales from a text style rather than a
  fixed point size.
- Command-Shift-R starts a recording and Command-Return saves one, so the journey works from the
  keyboard. On the Mac a global Option-Command-R works without the window.
- Recording state is communicated by symbol and text, not by color alone.

Outstanding: a full VoiceOver pass on a device, Increased Contrast verification, and focus-order
review for each sheet.
