#!/bin/bash
# Reuses only the explicitly supplied dedicated device. Does not boot/erase user devices.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
DEVICE="${1:?usage: run-probe.sh DEDICATED_SIMULATOR_UDID [case ...]}"
shift
CASES=("$@")
if ((${#CASES[@]} == 0)); then CASES=(success preview-lifecycle immediate not-running existing-file missing-directory session-stop remove-output drop-session remove-input interruption no-video no-audio denied-audio); fi
mkdir -p build/evidence
bash SimulatorInjection/Tests/build-probe.sh
SIMCAM_RECORDING_TESTS=1 zsh SimulatorInjection/build.sh "$ROOT/build/RecordingTestInjection"
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations -Wno-incompatible-pointer-types \
  -framework AVFoundation -framework CoreVideo -framework CoreMedia \
  SimulatorInjection/Tests/AnalyzeMovie.m -o build/AnalyzeMovie
xcrun simctl install "$DEVICE" build/RecordingProbe.app
xcrun simctl privacy "$DEVICE" grant camera com.dautov.RecordingProbe
xcrun simctl privacy "$DEVICE" grant microphone com.dautov.RecordingProbe
DATA="$(xcrun simctl get_app_container "$DEVICE" com.dautov.RecordingProbe data)"
for CASE in "${CASES[@]}"; do
  EXTRA=(SIMCTL_CHILD_SC_TEST_TONE=1)
  if [[ "$CASE" == no-video ]]; then EXTRA+=(SIMCTL_CHILD_SC_TEST_NO_VIDEO=1); fi
  if [[ "$CASE" == no-audio ]]; then EXTRA+=(SIMCTL_CHILD_SC_TEST_NO_AUDIO=1); fi
  if [[ "$CASE" == denied-audio ]]; then xcrun simctl privacy "$DEVICE" revoke microphone com.dautov.RecordingProbe; fi
  rm -f "$DATA/Documents/$CASE.json"
  env "${EXTRA[@]}" SIMCTL_CHILD_PROBE_CASE="$CASE" \
    SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$ROOT/build/RecordingTestInjection/libSimCamInject.dylib" \
    xcrun simctl launch --console-pty "$DEVICE" com.dautov.RecordingProbe > "build/evidence/$CASE.log" 2>&1
  if [[ "$CASE" == denied-audio ]]; then xcrun simctl privacy "$DEVICE" grant microphone com.dautov.RecordingProbe; fi
  cp "$DATA/Documents/$CASE.json" "build/evidence/$CASE.json"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r); assert r["pass"]' "build/evidence/$CASE.json"
  case "$CASE" in
    success|preview-lifecycle|session-stop|remove-output|drop-session|remove-input|interruption)
      for FILE in "$DATA/Documents/$CASE-"*.mov; do
        NAME="$(basename "$FILE")"
        cp "$FILE" "build/evidence/$NAME"
        build/AnalyzeMovie "build/evidence/$NAME" > "build/evidence/$NAME.json"
        python3 SimulatorInjection/Tests/check-fixture-asset.py "build/evidence/$NAME.json"
      done;;
  esac
done
echo 'PASS public movie-output probes and decoded audiovisual assets'
