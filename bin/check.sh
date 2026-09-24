#!/bin/bash
# Usage: bin/check.sh [--skip-e2e]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${STILL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Still-shared}"
UNIT_RESULT="${ROOT}/Artifacts/UnitTests.xcresult"
LOG="${ROOT}/Artifacts/check.log"
SKIP_E2E="${1:-}"

mkdir -p "${ROOT}/Artifacts"
: > "$LOG"

step() {
  local name="$1"
  shift
  local started=$SECONDS
  if "$@" >> "$LOG" 2>&1; then
    echo "✓ ${name} ($((SECONDS - started))s)"
  else
    echo "✗ ${name}. See Artifacts/check.log" >&2
    grep -E "error:|✘|failed -" "$LOG" | tail -10 >&2 || true
    exit 1
  fi
}

build_ios() {
  xcodebuild build \
    -project "${ROOT}/Still.xcodeproj" \
    -scheme Still-iOS \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
}

unit_tests() {
  rm -rf "$UNIT_RESULT"
  xcodebuild test \
    -project "${ROOT}/Still.xcodeproj" \
    -scheme Still-macOS \
    -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$UNIT_RESULT" \
    ${STILL_UNSIGNED:+CODE_SIGNING_ALLOWED=NO}
}

mcp_helper() {
  local helper="${DERIVED_DATA}/Build/Products/Debug/Still.app/Contents/Helpers/still-mcp"
  local reply
  reply=$(echo '{"jsonrpc":"2.0","id":9,"method":"tools/list"}' \
    | STILL_MCP_SOCKET="${TMPDIR:-/tmp}/still-mcp-missing.sock" "$helper")
  echo "$reply"
  [[ "$reply" == *'"code":-32001'* && "$reply" == *'"id":9'* ]]
}

step "Generate project" xcodegen generate --spec "${ROOT}/project.yml" --project "${ROOT}" --quiet
step "Build iOS" build_ios
step "macOS unit tests" unit_tests
step "MCP helper without Still" mcp_helper
xcrun xcresulttool get test-results summary --path "$UNIT_RESULT" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  %s of %s passed" % (d["passedTests"], d["totalTestCount"]))'

if [ "$SKIP_E2E" != "--skip-e2e" ]; then
  echo "… End-to-end on a fresh simulator"
  "${ROOT}/bin/e2e.sh" | sed 's/^/  /'
fi

echo "All checks passed."
