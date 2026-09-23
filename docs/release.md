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

The app record exists: "Still - AI note taker", Apple ID 6815369488, bundle ID `com.andrii.still`.
The API cannot create app records, so a new one is made once in the App Store Connect web page.

## fastlane does every store step

Every lane reads the App Store Connect key and team ID from 1Password (`op signin` first).

| Command | What it does |
|---|---|
| `fastlane doctor` | Checks the key and that the app record is reachable |
| `fastlane ios beta` / `fastlane mac beta` | Archives, signs and uploads a build to TestFlight |
| `fastlane ios metadata` / `fastlane mac metadata` | Uploads listing text from `fastlane/metadata*` and screenshots from `fastlane/screenshots/<platform>` |
| `fastlane ios submit` / `fastlane mac submit` | Submits the latest processed build for App Review |

App Privacy answers stay in App Store Connect: every data type is "Not collected" and tracking is
"No", matching `Still/Supporting/PrivacyInfo.xcprivacy`.

## Screenshots

Not produced yet. Required sizes are 6.9" and 6.5" iPhone, 13" iPad, and 1280×800 or larger for
Mac. They have to show the real app, so they come after a build runs on a device.

## Gates that are still open

Shipping is not only a signing problem. `docs/release-gates.md` lists what has not been measured
and why, and `docs/localization.md` records that no language other than English is translated.
Neither should be waved through to make a submission date.

## The toolchain CI uses has not been exercised

The workflow pins Xcode 26.6, the default on the `macos-26` runner. Development happens on
Xcode 27, and the code has been built and tested on Xcode 27.0 (`27A266a`) as well as 27.1, so it
does not depend on a beta. Nothing has compiled it with a 26.x toolchain, because none is
installed here.

If the first CI run fails to compile, that is the likeliest reason, and the fix is either to raise
`XCODE_VERSION` to a 27 image or to adjust whatever 27-only construct it names. The selection step
prints the resolved version and lists what the image has, so the run says which it used.
