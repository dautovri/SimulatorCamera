#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
DEVICE="${1:?dedicated simulator ID required}"
EVIDENCE="${2:?new evidence directory required}"
mkdir -p "$EVIDENCE"
bash SimulatorInjection/Tests/build-probe.sh
SIMCAM_RECORDING_TESTS=1 zsh SimulatorInjection/build.sh "$ROOT/build/RecordingTestInjection"
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations -framework AppKit -framework AVFoundation -framework CoreMedia -framework ImageIO SimulatorInjection/Tests/CheckOrientation.m -o build/CheckOrientation
xcrun simctl install "$DEVICE" build/RecordingProbe.app
xcrun simctl privacy "$DEVICE" grant camera com.dautov.RecordingProbe
xcrun simctl privacy "$DEVICE" grant microphone com.dautov.RecordingProbe
DATA="$(xcrun simctl get_app_container "$DEVICE" com.dautov.RecordingProbe data)"
python3 SimulatorInjection/Tests/publish-orientation-fixture.py --seconds 60 > "$EVIDENCE/fixture.log" 2>&1 &
FEED=$!
# Gracefully interrupt our own fixture only, allowing its inode-checked cleanup.
trap 'kill -TERM "$FEED" 2>/dev/null || true; wait "$FEED" 2>/dev/null || true' EXIT
python3 - <<'PY'
import os,time
deadline=time.monotonic()+5
while not os.path.exists('/private/tmp/SimulatorCamera/frame.bin'):
    if time.monotonic()>deadline: raise SystemExit('fixture did not start')
    time.sleep(.05)
PY
for ANGLE in ${ORIENTATION_ANGLES:-90 0 180 270}; do
  for MIRROR in ${ORIENTATION_MIRRORS:-0 1}; do
    CASE="orientation-$ANGLE-$MIRROR"
    rm -f "$DATA/Documents/$CASE.json" "$DATA/Documents/$CASE-preview.png"
    env SIMCTL_CHILD_SC_TEST_TONE=1 SIMCTL_CHILD_PROBE_CASE="$CASE" \
      SIMCTL_CHILD_PROBE_ORIENTATION_ANGLE="$ANGLE" SIMCTL_CHILD_PROBE_ORIENTATION_MIRROR="$MIRROR" \
      SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$ROOT/build/RecordingTestInjection/libSimCamInject.dylib" \
      xcrun simctl launch --console-pty "$DEVICE" com.dautov.RecordingProbe > "$EVIDENCE/$CASE.log" 2>&1
    cp "$DATA/Documents/$CASE.json" "$DATA/Documents/$CASE-preview.png" "$DATA/Documents/$CASE-1.mov" "$EVIDENCE/"
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["pass"]' "$EVIDENCE/$CASE.json"
    build/CheckOrientation "$EVIDENCE/$CASE-1.mov" "$ANGLE" "$MIRROR" "$EVIDENCE/$CASE-preview.png" "$EVIDENCE/$CASE-frame.png" | tee "$EVIDENCE/$CASE-check.log"
  done
done
