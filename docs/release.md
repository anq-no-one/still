# Releasing Still

## State of the Apple account

Team R3XFQ7K885, account holder anq.no.one@gmail.com.

Already registered, through the App Store Connect API:

- App ID `com.andrii.still`, platform UNIVERSAL, so one purchase covers iPhone, iPad and Mac
- Capabilities: iCloud with CloudKit, and In-App Purchase
- A Mac device entry, registered with the wrong identifier — see below

Verified end to end on this machine: a signed archive and an App Store export for both platforms,
producing `Still.pkg` and `Still-iOS.ipa`.

## Fix the Mac device registration first

The Mac was registered with its `IOPlatformUUID`. Apple wants the **provisioning UDID**, which is
a different value: System Information → Hardware → Provisioning UDID, `00006021-0010602C3ABB401E`
on the current build machine.

The consequence is verified rather than assumed. The team provisioning profile embedded in a
signed archive lists exactly one device, and it is the wrong identifier, so the built Mac app
refuses to launch here (`RBSRequestErrorDomain Code=5`, launchd spawn failure). Archiving and
exporting still succeed, because neither validates the running device.

    POST /v1/devices  {"attributes": {"name": "...", "platform": "MAC_OS", "udid": "<provisioning UDID>"}}

Then disable the wrong entry (`PATCH /v1/devices/<id>` with `"status": "DISABLED"`; Apple does not
delete device records) and rebuild so a fresh profile is issued.

Until this is done, one thing stays unproven: whether the encrypted Library unlocks on a properly
signed build. On the simulator the keychain returns `-34018` (`errSecMissingEntitlement`), but
simulator builds carry empty entitlements and an ad-hoc signature, so that result says nothing
about the product.

## The one thing the API cannot do

`POST /v1/apps` is refused by Apple:

    403 FORBIDDEN_ERROR — The resource 'apps' does not allow 'CREATE'

An app record has to be created in the App Store Connect web interface, or with a fastlane session
that answers a two-factor prompt. Everything downstream — uploading a build, TestFlight, the
in-app purchase, the listing — waits on that record.

Create it with: platforms iOS and macOS, bundle ID `com.andrii.still`, SKU `STILL-2026`, primary
language English (U.S.). If the name Still is taken, the bundle ID stays valid; only the listing
name changes.

## Then

1. `bin/release.sh both --upload` archives, exports and uploads. It needs `STILL_TEAM_ID` and an
   unlocked 1Password, and reads the App Store Connect key without putting it on a command line.
2. Create the non-consumable in-app purchase `com.andrii.still.pro` at $39.99, Family Sharing on.
   `Still/Supporting/Still.storekit` already describes it for local testing.
3. Upload the listing text with `fastlane deliver`. It lives in `fastlane/metadata/en-US/`.
4. Answer App Privacy in App Store Connect. Still collects nothing, so every data type is "Not
   collected" and tracking is "No". This matches `Still/Supporting/PrivacyInfo.xcprivacy`, which
   declares only three required-reason APIs: UserDefaults, file timestamps, and free disk space.

## Screenshots

Not produced yet. Required sizes are 6.9" and 6.5" iPhone, 13" iPad, and 1280×800 or larger for
Mac. They have to show the real app, so they come after a build runs on a device.

## Gates that are still open

Shipping is not only a signing problem. `docs/release-gates.md` lists what has not been measured
and why, and `docs/localization.md` records that no language other than English is translated.
Neither should be waved through to make a submission date.
