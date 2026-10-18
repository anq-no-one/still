#!/bin/bash
# One-authorization TestFlight run: sign in to 1Password once in this
# terminal, then build and upload both the iOS and macOS builds.
# Run it yourself with:  make testflight
set -euo pipefail
cd "$(dirname "$0")/.."

OP_ITEM="${STILL_OP_ASC_KEY_ITEM:-op://Personal/colouring - App Store Connect API}"

echo "-- 1Password sign-in (the only authorization this run needs)"
op signin --account my.1password.com

echo "-- Reading TestFlight credentials into this shell only"
export STILL_OP_TEAM_ID="$(op read "$OP_ITEM/TEAM_ID")"
export STILL_OP_APP_STORE_KEY_ID="$(op read "$OP_ITEM/APP_STORE_KEY_ID")"
export STILL_OP_APP_STORE_ISSUER_ID="$(op read "$OP_ITEM/APP_STORE_ISSUER_ID")"
export STILL_OP_APP_STORE_KEY_CONTENT="$(op read "$OP_ITEM/APP_STORE_KEY_CONTENT")"

echo "-- iOS TestFlight build and upload"
fastlane ios beta

echo "-- macOS TestFlight build and upload"
fastlane mac beta

echo "-- done: signed archives and dSYMs are in Release/build/"
