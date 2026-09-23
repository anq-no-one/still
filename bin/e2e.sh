#!/bin/bash
# Usage: bin/e2e.sh [--device <udid>] [--only <test name>]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${STILL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Still-shared}"
RESULT="${ROOT}/Artifacts/E2E.xcresult"
MODEL_ROOT="${STILL_E2E_MODEL_ROOT:-$HOME/Library/Caches/Still-E2E/Models}"
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
  mkdir -p "$MODEL_ROOT"
  export TEST_RUNNER_STILL_MODEL_ROOT="$MODEL_ROOT"
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

SCREENS="${ROOT}/Artifacts/E2E-screens"
rm -rf "$SCREENS"
mkdir -p "$SCREENS"
if xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SCREENS" >/dev/null 2>&1; then
  python3 - "$SCREENS" <<'PY'
import json, os, sys
root = sys.argv[1]
for test in json.load(open(os.path.join(root, "manifest.json"))):
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "")
        exported = os.path.join(root, attachment["exportedFileName"])
        if name.endswith(".png") and name[0].isdigit():
            os.rename(exported, os.path.join(root, name.split("_")[0] + ".png"))
        else:
            os.remove(exported)
os.remove(os.path.join(root, "manifest.json"))
PY
  echo "Screenshots: Artifacts/E2E-screens"
fi

exit "$STATUS"
