#!/bin/bash
# Runs the end-to-end suite against a real Still build.
#
# On a simulator the run needs nobody: it creates its own device, keeps it
# silent, enrolls Face ID and approves every Face ID request, then deletes the
# device. On a physical device Face ID is real, so reopening the Library after
# relaunch waits for the person holding the phone.
#
# Usage: bin/e2e.sh [--device <udid>] [--only <test name>]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${STILL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Still-shared}"
RESULT="${ROOT}/Artifacts/E2E.xcresult"
DEVICE=""
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

SIMULATOR=""
MATCHER=""

cleanup() {
  if [ -n "$MATCHER" ]; then kill "$MATCHER" 2>/dev/null || true; fi
  if [ -n "$SIMULATOR" ]; then
    xcrun simctl shutdown "$SIMULATOR" 2>/dev/null || true
    xcrun simctl delete "$SIMULATOR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mute_sim_audio() {
  local settings
  settings="$(xcrun simctl getenv "$1" SIMULATOR_SHARED_RESOURCES_DIRECTORY)/var/run/simulatoraudio/audiosettings.plist"
  if [ -f "$settings" ]; then
    plutil -replace sim_volume -integer 0 "$settings"
  fi
}

enroll_face_id() {
  xcrun simctl spawn "$1" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
  xcrun simctl spawn "$1" notifyutil -p com.apple.BiometricKit.enrollmentChanged
}

approve_face_id_forever() {
  while true; do
    xcrun simctl spawn "$1" notifyutil -p com.apple.BiometricKit_Sim.pearl.match >/dev/null 2>&1 || true
    sleep 2
  done
}

xcodegen generate --spec "${ROOT}/project.yml" --project "${ROOT}" --quiet

if [ -n "$DEVICE" ]; then
  DESTINATION="id=${DEVICE}"
else
  DEVICE_TYPE="$(xcrun simctl list devicetypes | grep -m1 -E '^iPhone 1[6-9] Pro \(' | sed -E 's/ \(.*//')"
  SIMULATOR="$(xcrun simctl create still-e2e "$DEVICE_TYPE")"
  xcrun simctl boot "$SIMULATOR"
  xcrun simctl bootstatus "$SIMULATOR" >/dev/null
  mute_sim_audio "$SIMULATOR"
  enroll_face_id "$SIMULATOR"
  approve_face_id_forever "$SIMULATOR" &
  MATCHER=$!
  DESTINATION="id=${SIMULATOR}"
fi

rm -rf "$RESULT"
mkdir -p "$(dirname "$RESULT")"

SELECTION=()
if [ -n "$ONLY" ]; then
  SELECTION=(-only-testing "StillUITests/StillEndToEndTests/${ONLY}")
fi

set +e
xcodebuild test \
  -project "${ROOT}/Still.xcodeproj" \
  -scheme Still-iOS \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT" \
  -parallel-testing-enabled NO \
  -allowProvisioningUpdates \
  "${SELECTION[@]+"${SELECTION[@]}"}" \
  > "${ROOT}/Artifacts/E2E.log" 2>&1
STATUS=$?
set -e

xcrun xcresulttool get test-results summary --path "$RESULT" 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s: %s passed, %s failed of %s" % (d.get("result"), d.get("passedTests"), d.get("failedTests"), d.get("totalTestCount")))' \
  || echo "No test results. See Artifacts/E2E.log."

xcrun xcresulttool get test-results tests --path "$RESULT" 2>/dev/null \
  | python3 -c '
import json, sys
def walk(node):
    if node.get("nodeType") == "Failure Message":
        print("  " + node.get("name", ""))
    for child in node.get("children", []):
        walk(child)
for node in json.load(sys.stdin).get("testNodes", []):
    walk(node)
' || true

exit "$STATUS"
