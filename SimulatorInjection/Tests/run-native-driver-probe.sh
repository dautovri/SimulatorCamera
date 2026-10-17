#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
DEVICE="${1:?usage: run-native-driver-probe.sh DEDICATED_SIMULATOR_UDID MEDIA_SOURCE_PATH [fixture|live]}"
SOURCE="${2:?provide original downstream app Media source path}"
MODE="${3:-fixture}"
bash SimulatorInjection/Tests/build-native-driver-probe.sh "$SOURCE"
xcrun simctl install "$DEVICE" build/NativeDriverProbe.app
xcrun simctl privacy "$DEVICE" grant camera com.dautov.NativeDriverProbe
xcrun simctl privacy "$DEVICE" grant microphone com.dautov.NativeDriverProbe
DATA="$(xcrun simctl get_app_container "$DEVICE" com.dautov.NativeDriverProbe data)"
rm -f "$DATA/Documents/native-result.txt"
rm -f "$DATA/Documents/native-recording-ready" "$DATA/Documents/native-replay-ready"
EXTRA=(SIMCTL_CHILD_SC_TEST_TONE=1)
LIB="$ROOT/build/RecordingTestInjection/libSimCamInject.dylib"
if [[ "$MODE" == live ]]; then
  zsh SimulatorInjection/build.sh
  LIB="$ROOT/build/SimulatorInjection/libSimCamInject.dylib"
  EXTRA=(SIMCTL_CHILD_SC_TEST_TONE=0) # Production library has no test tone code.
  xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreMedia SimulatorInjection/Tests/HostAudioFeed.m -o build/HostAudioFeed
  build/HostAudioFeed 'BlackHole 2ch' 15 'MacBook Air Microphone' > build/evidence/live-microphone-feed.log 2>&1 &
  FEED=$!
fi
env "${EXTRA[@]}" SIMCTL_CHILD_SIMCAM_RECORDING_LOG=1 SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$LIB" \
  xcrun simctl launch --console-pty "$DEVICE" com.dautov.NativeDriverProbe > "build/evidence/native-$MODE.log" 2>&1 &
LAUNCH=$!
# Wait for app-observed states, not a fixed rendering delay. Capture only this app.
wait_for_state() {
  python3 - "$1" <<'PY'
import pathlib, sys, time
path = pathlib.Path(sys.argv[1])
deadline = time.monotonic() + 20
while not path.exists():
    if time.monotonic() > deadline:
        raise SystemExit("Timed out waiting for " + str(path))
    time.sleep(0.1)
PY
}
wait_for_state "$DATA/Documents/native-recording-ready"
xcrun simctl io "$DEVICE" screenshot "build/evidence/native-$MODE-recording.png"
wait_for_state "$DATA/Documents/native-replay-ready"
xcrun simctl io "$DEVICE" screenshot "build/evidence/native-$MODE-replay.png"
wait "$LAUNCH"
if [[ "$MODE" == live ]]; then wait "$FEED"; fi
cp "$DATA/Documents/native-result.txt" "build/evidence/native-$MODE-result.txt"
grep -q '^PASS' "build/evidence/native-$MODE-result.txt"
for TAKE in 1 2; do
  cp "$DATA/Documents/native-$TAKE.mov" "build/evidence/native-$MODE-$TAKE.mov"
  build/AnalyzeMovie "build/evidence/native-$MODE-$TAKE.mov" > "build/evidence/native-$MODE-$TAKE.json"
done
rm -f "$DATA/Documents/native-result.txt"
env "${EXTRA[@]}" SIMCTL_CHILD_NATIVE_CANCEL=1 SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$LIB" \
  xcrun simctl launch --console-pty "$DEVICE" com.dautov.NativeDriverProbe > "build/evidence/native-$MODE-cancel.log" 2>&1
cp "$DATA/Documents/native-result.txt" "build/evidence/native-$MODE-cancel-result.txt"
grep -q '^PASS' "build/evidence/native-$MODE-cancel-result.txt"
echo "PASS exact native driver ($MODE): two recordings, playback, startup cancellation"
