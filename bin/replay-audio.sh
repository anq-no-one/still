#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATION_ROOT="${STILL_VALIDATION_ROOT:-$HOME/Library/Caches/Still-Validation}"
DERIVED_DATA="${STILL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Still-shared}"
mkdir -p "$VALIDATION_ROOT"

if [[ $# -lt 2 ]]; then
  echo 'usage: bin/replay-audio.sh <exported-recording-directory> <mixed.wav> [model-root] [output-directory]' >&2
  exit 64
fi

CONFIG="$HOME/Downloads/Still-Replay-Configuration.json"
MODEL_ROOT="${3:-$HOME/Library/Containers/com.andrii.still/Data/Library/Application Support/Still/Models}"
OUTPUT_ROOT="${4:-$HOME/Library/Containers/com.andrii.still/Data/Library/Caches/Still-Validation/audio-replay}"
python3 - "$1" "$2" "$MODEL_ROOT" "$OUTPUT_ROOT" "$CONFIG" <<'PY'
import json
import os
import pathlib
import sys
paths = [pathlib.Path(p).expanduser().resolve() for p in sys.argv[1:5]]
config = dict(zip(['recordingDirectory', 'mixedAudio', 'modelRoot', 'outputDirectory'], [p.as_uri() for p in paths]))
config['iterations'] = int(os.environ.get('STILL_REPLAY_ITERATIONS', '2'))
config['transcribe'] = os.environ.get('STILL_REPLAY_TRANSCRIBE', '1') != '0'
with open(sys.argv[5], 'w') as handle:
    json.dump(config, handle, indent=2)
os.chmod(sys.argv[5], 0o600)
PY

xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" --quiet
xcodebuild test \
  -project "$ROOT/Still.xcodeproj" \
  -scheme Still-macOS \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -parallel-testing-enabled NO \
  -only-testing:StillTests/ActualAudioReplayTests \
  "STILL_REPLAY_CONFIG=$CONFIG" \
  > "$VALIDATION_ROOT/audio-replay.log" 2>&1
echo "Replay passed. Private results: $OUTPUT_ROOT"
echo "Build/test log: $VALIDATION_ROOT/audio-replay.log"
