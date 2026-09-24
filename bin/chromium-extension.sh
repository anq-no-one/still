#!/bin/bash
# Usage: bin/chromium-extension.sh
# Builds Artifacts/ChromiumExtension (load unpacked) and Artifacts/StillChromiumExtension.zip (store upload).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="${ROOT}/StillBrowserExtension/Resources"
UNPACKED="${ROOT}/Artifacts/ChromiumExtension"
STORE="${ROOT}/Artifacts/ChromiumExtensionStore"
ZIP="${ROOT}/Artifacts/StillChromiumExtension.zip"

rm -rf "$UNPACKED" "$STORE" "$ZIP"
mkdir -p "$UNPACKED" "$STORE"

for dir in "$UNPACKED" "$STORE"; do
  cp "${ROOT}/ChromiumExtension/background.js" "${SHARED}/meeting.js" "${SHARED}/sites.js" "$dir/"
done
cp "${ROOT}/ChromiumExtension/manifest.json" "$UNPACKED/manifest.json"

python3 - "${ROOT}/ChromiumExtension/manifest.json" "${STORE}/manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
manifest.pop("key", None)
json.dump(manifest, open(sys.argv[2], "w"), indent=2)
PY

(cd "$STORE" && zip -qrX "$ZIP" manifest.json background.js meeting.js sites.js)
rm -rf "$STORE"

echo "Unpacked: ${UNPACKED}"
echo "Store zip: ${ZIP}"
