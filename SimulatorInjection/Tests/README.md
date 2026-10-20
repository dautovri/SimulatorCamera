# Movie recording verification

Run only on an isolated Simulator with disposable app data. No system extension,
host camera, or microphone capture is needed for the deterministic suite. The
probe imports only UIKit/AVFoundation and calls the public movie-output API.

## Deterministic public-API suite

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun simctl list runtimes
xcrun simctl create SimulatorCamera-Recording-Probe \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
# Use the returned dedicated ID, not "booted".
DEVICE=<dedicated-id>
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
bash SimulatorInjection/Tests/run-probe.sh "$DEVICE"
```

The suite builds a **test-only** injection library under
`build/RecordingTestInjection/`. Its synthetic 440 Hz PCM source replaces only
the microphone boundary; encoding, timestamps, file finalization, session hooks,
and recording delegates use production code. Test-only switches also suppress
audio/video delivery to exercise startup timeout failures. These switches are
compiled out of normal `SimulatorInjection/build.sh` builds.

Cases cover attaching a preview before session configuration and releasing its
connection after recording, two takes with different rotation/mirroring, immediate repeated stop,
not-running session, existing/missing destination, session stop, output removal,
session release, camera-input removal, interruption, missing audio/video, and
truthful native microphone permission denial. Permission denial is rejected by
the real microphone-input initializer, before recording begins.

`AnalyzeMovie.m` uses real `AVAssetReader` decoding. The checks require changing
video pixels, nonzero audio with the expected RMS/frequency, monotonic sample
timestamps, independent transform expectations, and bounded track start/end
differences. Track presence or successful callbacks alone are not sufficient.
Timing checks establish muxed track alignment, **not physical camera/microphone
lip-sync latency**. Artifacts and logs go to ignored `build/evidence/`.

Run one case by appending its name, for example:

```sh
bash SimulatorInjection/Tests/run-probe.sh "$DEVICE" immediate
```

## Exact caller integration

After the public suite has built its tools:

```sh
bash SimulatorInjection/Tests/run-native-driver-probe.sh "$DEVICE" \
  /path/to/downstream-app/app/Sources/Media fixture
```

This compiles the actual caller's Media sources in place, read-only, with Swift 6
complete concurrency checking; hashes are retained with the evidence. The app
uses `NativeVideoCaptureDriver` and `AudioSessionLease` unchanged to record twice,
stop/finalize, and replay with `AVPlayer`. A separate launch cancels startup and
then records again. Playback is muted to keep fixtures out of the host speakers.
Screenshots show only this isolated app and must be inspected separately.

## Real microphone proof

Use a normal production library build and a live host microphone route for this
proof. Fixtures do not establish real microphone capture. On the assessment
machine the default input is an existing **BlackHole 2ch** virtual device. The
optional `live` mode uses `HostAudioFeed.m` to bridge **MacBook Air Microphone**
into that device for 15 seconds, selecting both devices only inside the helper
process. It does not change global audio defaults or install a driver:

```sh
bash SimulatorInjection/Tests/run-native-driver-probe.sh "$DEVICE" \
  /path/to/downstream-app/app/Sources/Media live
```

This machine-specific mode requires those two existing devices and already
authorized host microphone access. If unavailable, configure a suitable route
yourself or report the remaining live-capture gate; do not bypass permissions.
The helper reports live input sample count/RMS; finalized movies must separately
pass nonzero-audio decoding. Quiet surroundings can legitimately fail that proof.
Live video in this harness is the animated injection test pattern, not a claim
of Mac webcam capture.

## Webcam orientation regression

The camera transport publishes an already-upright host image. Its portrait
reference is 90°; the effective display rotation is the requested connection
angle minus that reference, followed by display-space mirroring. The ordinary
test pattern's sensor-coordinate transform tests retain their zero reference.

```sh
bash SimulatorInjection/Tests/run-orientation-probe.sh "$DEVICE" \
  "$PWD/build/evidence/new-orientation-run"
```

This publishes a labeled, asymmetric four-color image through the actual frame
store with the camera tag, then records via the public movie-output API. It
independently checks the expected visual corner positions at 0/90/180/270°,
mirrored and unmirrored, in both preview pixels and the decoded movie. Extraction
uses `AVAssetImageGenerator.appliesPreferredTrackTransform`, as a normal player
does; no corrective rotation is applied. The fixture refuses to overwrite an
existing frame store and cleans up only its own inode.

For a separately authorized short **physical webcam plus microphone** check,
build the production dylib, native-driver probe and analysis tools, then:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SimulatorCamera.xcodeproj -scheme simcamctl -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/WebcamVerification \
  CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun clang \
  -fobjc-arc -fmodules -Wno-deprecated-declarations -framework AVFoundation \
  -framework CoreMedia -framework ImageIO SimulatorInjection/Tests/ExtractMovieFrames.m \
  -o build/ExtractMovieFrames
python3 SimulatorInjection/Tests/run-webcam-probe.py "$DEVICE" \
  "$PWD/build/evidence/new-physical-webcam-run"
```

The runner waits for fresh advancing camera-tagged frames before launching the
unchanged caller. It retains original movies, screenshots, decoded frames and
audio/video measurements, waits for its short capture processes to end, and
removes only its own raw frame file. Inspect the screenshots and extracted frames
yourself before claiming upright webcam behavior. The microphone bridge has the
same machine-specific prerequisites described above; playback is muted and this
does not establish perceptual audio quality or physical lip-sync.

## Existing contract suite and cleanup

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SimulatorCamera.xcodeproj -scheme SimulatorCamera \
  -destination 'platform=macOS' -derivedDataPath build/MacTests \
  -only-testing:SimulatorCameraTests CODE_SIGNING_ALLOWED=NO test
xcrun simctl shutdown "$DEVICE"
```

Keep the dedicated device and local evidence until review is complete. No normal
app data, other simulators, system-extension registrations, or security settings
need changing. Normal production builds create both arm64 and x86_64 slices;
the current probe app build targets arm64.
