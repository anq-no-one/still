# Localization and accessibility

## Supported interface languages

English (source), German, Spanish, French, Italian, Dutch, Polish, Portuguese (Portugal), Russian,
Swedish, Ukrainian. These match the App Store listing locales in `fastlane/metadata*`.

## Files

- `Still/Supporting/Localizable.xcstrings`: every string the app shows. `SWIFT_EMIT_LOC_STRINGS` extracts
  SwiftUI literals and `String(localized:)` on build.
- `Still/Supporting/InfoPlist.xcstrings`: the system permission prompts.

## Updating translations

1. Build (`bin/check.sh --skip-e2e`), then run `bin/localize.py sync` to add new strings and drop unused ones.
2. `bin/localize.py missing <lang> <file.json>` writes the strings a language lacks.
3. Translate the file, keeping format specifiers and Apple's own terms for the language.
4. `bin/localize.py apply <lang> <file.json>` merges it back.

## Open checks

- Truncation at the longest translations and plural forms need a pass in each language.
- Privacy and permission wording should get a native-speaker review before release.

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

`testPrimaryScreensPassTheAccessibilityAudit` runs Xcode's accessibility audit on setup, the library,
Settings, Access, the capture sheet and a saved recording. It passes on iPhone. Run it on iPad with
`STILL_E2E_DEVICE_TYPE="iPad Pro 11-inch (M5)" bin/e2e.sh --only testPrimaryScreensPassTheAccessibilityAudit`;
there one issue remains: the speaker name under a transcript time stamp reports partial Dynamic Type
support in the iPad split view. The audit ignores contrast warnings marked "nearly passed", issues it
cannot tie to an element, and controls the system draws (Done, the search field, the sidebar title).

Outstanding: a full VoiceOver pass on a device, Increased Contrast verification, and focus-order
review for each sheet.
