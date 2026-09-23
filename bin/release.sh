#!/bin/bash
# Archives, exports, and uploads Still.
#
# Credentials are read straight from 1Password into this process and are never
# printed, written to the repository, or passed on a command line.
#
#   STILL_TEAM_ID          Apple Developer team the build is signed for
#   STILL_OP_ASC_KEY_ITEM  1Password item holding the App Store Connect API key
#
# Usage: bin/release.sh [ios|macos|both] [--upload]

set -euo pipefail

PLATFORM="${1:-both}"
UPLOAD="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT}/Release/build"
TEAM_ID="${STILL_TEAM_ID:-}"
ASC_ITEM="${STILL_OP_ASC_KEY_ITEM:-op://Personal/colouring - App Store Connect API}"

if [ -z "$TEAM_ID" ]; then
  echo "Set STILL_TEAM_ID to the Apple Developer team this build belongs to." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"
xcodegen generate --spec "${ROOT}/project.yml" --project "${ROOT}"

archive() {
  local scheme="$1" destination="$2" archive="$3"

  xcodebuild archive \
    -project "${ROOT}/Still.xcodeproj" \
    -scheme "$scheme" \
    -destination "$destination" \
    -archivePath "$archive" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    -allowProvisioningUpdates
}

export_archive() {
  local archive="$1" options="$2" output="$3"

  sed "s/\${STILL_TEAM_ID}/${TEAM_ID}/" "$options" > "${BUILD_DIR}/ExportOptions.resolved.plist"
  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.resolved.plist" \
    -exportPath "$output" \
    -allowProvisioningUpdates
}

# Writes the .p8 to a private file rather than an argument, so the key never
# appears in the process list or in any log.
fetch_api_key() {
  local dir="${TMPDIR:-/tmp}/still-asc.$$"
  mkdir -p "$dir"
  chmod 700 "$dir"

  KEY_ID="$(op read "${ASC_ITEM}/APP_STORE_KEY_ID")"
  ISSUER_ID="$(op read "${ASC_ITEM}/APP_STORE_ISSUER_ID")"
  op read "${ASC_ITEM}/APP_STORE_KEY_CONTENT" | base64 --decode > "${dir}/AuthKey_${KEY_ID}.p8"
  chmod 600 "${dir}/AuthKey_${KEY_ID}.p8"
  API_KEY_DIR="$dir"
}

upload() {
  local package="$1"

  fetch_api_key
  trap 'rm -rf "$API_KEY_DIR"' EXIT

  API_PRIVATE_KEYS_DIR="$API_KEY_DIR" xcrun altool --upload-app \
    --type "$2" \
    --file "$package" \
    --apiKey "$KEY_ID" \
    --apiIssuer "$ISSUER_ID"
}

if [ "$PLATFORM" = "ios" ] || [ "$PLATFORM" = "both" ]; then
  archive Still-iOS "generic/platform=iOS" "${BUILD_DIR}/Still-iOS.xcarchive"
  export_archive "${BUILD_DIR}/Still-iOS.xcarchive" "${ROOT}/Release/ExportOptions-iOS.plist" "${BUILD_DIR}/ios"
  [ "$UPLOAD" = "--upload" ] && upload "${BUILD_DIR}/ios/Still.ipa" ios
fi

if [ "$PLATFORM" = "macos" ] || [ "$PLATFORM" = "both" ]; then
  archive Still-macOS "generic/platform=macOS" "${BUILD_DIR}/Still-macOS.xcarchive"
  export_archive "${BUILD_DIR}/Still-macOS.xcarchive" "${ROOT}/Release/ExportOptions-macOS.plist" "${BUILD_DIR}/macos"
  [ "$UPLOAD" = "--upload" ] && upload "${BUILD_DIR}/macos/Still.pkg" macos
fi

echo "Archives and exports are in ${BUILD_DIR}"
