#!/bin/bash
# One-authorization TestFlight run: sign in to 1Password once in this
# terminal, then build and upload both the iOS and macOS builds.
# Run it yourself with:  make testflight
#
# Everything this script prints goes to Artifacts/testflight.log
# (gitignored), so a failure can be diagnosed from the log alone.
# Secrets are never printed: they travel only in environment variables.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p Artifacts
LOG="Artifacts/testflight.log"
echo "-- TestFlight run started at $(date -u +%Y-%m-%dT%H:%M:%SZ) from commit $(git rev-parse --short HEAD)" | tee "$LOG"
exec > >(tee -a "$LOG") 2>&1

OP_ITEM="${STILL_OP_ASC_KEY_ITEM:-op://Personal/colouring - App Store Connect API}"

op_read() {
  local value
  if value="$(op read "$1" 2>/dev/null)"; then
    printf '%s' "$value"
    return 0
  fi
  echo "!! Could not read $1"
  echo "-- 1Password item names visible to this sign-in (titles only, no secrets):"
  op item list --format json 2>/dev/null | python3 -c "
import json,sys
for item in json.load(sys.stdin):
    print('   ', item.get('vault',{}).get('name','?'), '/', item.get('title','?'))
" || op item list || true
  return 1
}

if [[ -n "${STILL_ASC_KEY_FILE:-}" ]]; then
  echo "-- Key-file mode: using $STILL_ASC_KEY_FILE, no 1Password needed"
  : "${STILL_ASC_KEY_ID:?set STILL_ASC_KEY_ID to the key's 10-character ID}"
  : "${STILL_ASC_ISSUER_ID:?set STILL_ASC_ISSUER_ID to the team's issuer UUID}"
  : "${STILL_TEAM_ID:?set STILL_TEAM_ID to the 10-character team ID}"
  export STILL_OP_TEAM_ID="$STILL_TEAM_ID"
  export STILL_OP_APP_STORE_KEY_ID="$STILL_ASC_KEY_ID"
  export STILL_OP_APP_STORE_ISSUER_ID="$STILL_ASC_ISSUER_ID"
  export STILL_OP_APP_STORE_KEY_CONTENT="key-file-mode"
else
  echo "-- 1Password sign-in (the only authorization this run needs)"
  op signin --account my.1password.com
  op whoami

  echo "-- Reading TestFlight credentials into this shell only"
  export STILL_OP_TEAM_ID="$(op_read "$OP_ITEM/TEAM_ID")"
  export STILL_OP_APP_STORE_KEY_ID="$(op_read "$OP_ITEM/APP_STORE_KEY_ID")"
  export STILL_OP_APP_STORE_ISSUER_ID="$(op_read "$OP_ITEM/APP_STORE_ISSUER_ID")"
  export STILL_OP_APP_STORE_KEY_CONTENT="$(op_read "$OP_ITEM/APP_STORE_KEY_CONTENT")"
fi

check_shape() {
  local field="$1" value="$2" ok=1 detail=""
  case "$field" in
    TEAM_ID | APP_STORE_KEY_ID)
      [[ "$value" =~ ^[A-Z0-9]{10}$ ]] || { ok=0; detail="want 10 uppercase letters/digits"; } ;;
    APP_STORE_ISSUER_ID)
      [[ "$value" =~ ^[0-9a-fA-F-]{36}$ ]] || { ok=0; detail="want a 36-character UUID"; } ;;
    APP_STORE_KEY_CONTENT)
      if [[ "$value" == *BEGIN* ]]; then
        (( ${#value} > 150 && ${#value} < 4000 )) || { ok=0; detail="PEM looks truncated or padded"; }
      else
        [[ "$value" =~ ^[A-Za-z0-9+/=$'\n']+$ && ${#value} -gt 100 ]] || { ok=0; detail="want the .p8 PEM text or its base64"; }
      fi ;;
  esac
  local status="ok"
  (( ok )) || status="MALFORMED ($detail)"
  echo "-- credential $field: length=${#value} $status"
  return $((1 - ok))
}

if [[ -z "${STILL_ASC_KEY_FILE:-}" ]]; then
  valid=0
  for field in TEAM_ID APP_STORE_KEY_ID APP_STORE_ISSUER_ID APP_STORE_KEY_CONTENT; do
    var="STILL_OP_$field"
    check_shape "$field" "${!var}" || valid=1
  done
  if (( valid )); then
    echo "!! Fix the fields of '$OP_ITEM' in 1Password (or point STILL_OP_ASC_KEY_ITEM at the right item), then re-run."
    exit 1
  fi
fi

echo "-- iOS TestFlight build and upload"
fastlane ios beta

echo "-- macOS TestFlight build and upload"
fastlane mac beta

echo "-- done: signed archives and dSYMs are in Release/build/"
