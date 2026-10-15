# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Frame transport rewritten on CoreMediaIO sink streams.** The v1.0.0 design
  pushed frames into the camera extension over a private `NSXPCListener`.
  Apple DTS classes that as unsupported (the extension runs as the
  `_cmiodalassistants` role user, so the app's Mach lookup never reaches it),
  and it never worked end-to-end. The extension now publishes a sink stream
  (`SimulatorCamera.Video.Sink`) next to the camera stream; the app and
  `simcamctl` open it through the CoreMediaIO C API and enqueue IOSurface-
  backed `CMSampleBuffer`s, which the extension re-sends on the camera stream
  without copying pixels. Control (source kind, status) travels as custom
  properties on the camera stream. `Shared/XPCContract.swift`,
  `XPCListener.swift` and `XPCClient.swift` are gone; `Shared/CameraContract.swift`,
  `Shared/CMIOSinkClient.swift` and `SimulatorCamera/CameraLink.swift` replace them.
- Virtual camera format is 1280x720 BGRA @ 30 fps (was 1920x1080 @ 60 with
  1280x720 payloads that never rendered). Every source is normalized to that
  geometry once, with a shared `CIContext` and pixel-buffer pool.
- Image, QR and simcamctl share one rasterizer (`FrameRaster`, `QRRenderer`)
  that draws straight into IOSurface-backed pixel buffers.
- `simcamctl status` shows sink state and the extension's received / rejected
  frame counters; `ping` confirms the device and its properties are reachable.
  Exit code 2 now means "virtual camera not registered".
- The container app declares `com.apple.security.device.camera` (needed to
  start a CMIO stream from the sandbox).

### Fixed
- **Test-pattern timer leak.** Each CMIO client that started streaming created
  a new timer without cancelling the previous one; orphaned timers kept emitting
  at full rate forever. Only the first client creates the timer now.
- **Host-clock timestamps.** Frames are stamped with the host clock on both
  sides; source-relative (sometimes negative) seconds no longer reach
  `UInt64` conversions.
- **Extension never stalls the consumer.** With a producer selected but quiet
  the last frame is re-sent with fresh timestamps; with none delivered yet the
  stripe pattern shows. Frames that arrive while the test pattern is selected
  are consumed and ignored, so a stray producer cannot override the choice.
- **Sink producers are gated** to binaries whose signing ID matches the
  extension's own bundle-ID prefix (`…SimulatorCamera`, `…simcamctl`).
- **Source switching is race-free.** Rapid switches are serialized by a
  generation counter; a camera that finishes warming up after a newer switch is
  stopped instead of leaking. The sink is opened before the producer starts and
  the extension learns the new source only once frames are flowing.
- **Camera link recovers on its own.** Device discovery retries with capped
  backoff and re-attaches on `AVCaptureDevice.wasConnectedNotification` (which
  fires when the extension registers). Status is polled once a second.
- **Video file source** cancels its reader on stop, stops instead of spinning
  on unreadable files, clamps negative PTS, and paces against the wall clock.
- **Mac camera source** honours a `stop()` that lands while the session is
  still starting, and never selects the virtual camera as its own input.
- Extension state is queried at launch (`propertiesRequest`) so a relaunched
  app shows "Active" instead of "Not checked". Leftover activation diagnostics
  that wrote files into `~/Library/Logs` are gone.

### Added
- `SimulatorCameraTests`: 20 logic tests for the contract, status encoding,
  frame validation, sink-client edge cases, raster helpers and QR rendering.
  CI runs them.
- Diagnostics in the UI: camera-link state, whether any app is capturing from
  the virtual camera, and frames dropped / rejected on both sides.

## [1.0.0] — 2026-04-26

**Architectural rewrite.** v1.0.0 abandons the v0.x TCP/SDK approach in
favor of Apple's `CMIOExtension` system extension. The iOS Simulator
(Xcode 16+) sees a real virtual camera through standard `AVFoundation`.
**No SDK to import. No `Info.plist` key required in your app. No
`#if targetEnvironment(simulator)` branches.**

### Added
- **macOS Camera Extension** (`SimulatorCameraExtension.systemextension`)
  bundled inside the container app, registers as "SimulatorCamera Virtual"
  in `AVCaptureDevice.devices(for: .video)`.
- **Container app** (`SimulatorCamera.app`) submits
  `OSSystemExtensionRequest` activation, hosts SwiftUI source picker,
  pumps frames into the extension over XPC.
- **Five frame sources:**
  - Test pattern (built into extension; works with no setup)
  - Mac webcam (`AVCaptureSession` on host)
  - Video file (`AVAssetReader`, MP4/MOV/HEVC, loops at EOF)
  - Static image (PNG/JPG, letterboxed to 1280x720)
  - QR code generator (any UTF-8 string)
- **`simcamctl` CLI** — `simcamctl set-source --qr "..."`,
  `--image PATH`, `--pattern`, `status`, `ping`. Useful for AI agents
  + CI that need deterministic frame fixtures.
- **`patches/` directory** — `patch-package`-compatible patches for
  `expo-camera < 55.0.11`, `react-native-vision-camera < 5.0`,
  `react-native-webrtc`, `@fishjam-cloud/react-native-webrtc`. These
  libraries hard-code `#if targetEnvironment(simulator)` to disable the
  camera; we patch around the guard.
- **XcodeGen project** (`project.yml`) — Xcode project regenerable from
  YAML, suitable for `git diff`-friendly review.
- **Run Diagnostics UI** in container app — XPC connection state,
  extension activation state, frame counter.

### Changed
- **Tagline:** "Stream a real camera into the iOS Simulator" → "Your
  Mac's camera, in the iOS Simulator. Free and open." Positions
  SimulatorCamera as Act 1 of the Simulator's missing sensor layer
  (microphone, BLE, motion, LiDAR coming in v2+).
- **Min macOS:** 13.0 (Ventura) → 14.0 (Sonoma) for `@Observable` +
  `@Environment(.self)` SwiftUI APIs.
- **Distribution:** arm64-only. Intel Macs not supported in v1.x.
- **Bundle ID:** `com.simulatorcamera.server` →
  `com.dautov.SimulatorCamera` (container) +
  `com.dautov.SimulatorCamera.Extension` (system extension).

### Removed
- **Entire iOS SDK** (`SimulatorCameraClient` Swift Package). The new
  architecture requires zero iOS SDK; user apps go through
  `AVFoundation` unchanged.
- **TCP server** (`SimulatorCameraServer` CLI). Replaced by the system
  extension's XPC interface.
- **SCMF wire protocol.** Frames now flow through Apple's
  `CMIOExtensionStream` infrastructure.
- **`SimulatorCameraSession`, `SimulatorCameraPreviewView`, `SimulatorCameraView`,
  `SimulatorCaptureSession`, `SimulatorCameraOutput`** — all v0.x SDK types
  gone. User code that imported `SimulatorCameraClient` must drop the
  import; the camera "just works" through standard AVFoundation.
- **iOS demo app** (`apps/iOSDemo/`). With no SDK, no demo is needed —
  any iOS Simulator app that uses `AVCaptureDevice` IS the demo.
- **`NSLocalNetworkUsageDescription` requirement.** No more local
  network — XPC is in-process to the system extension.
- **SwiftPM `Package.swift`.** System extensions cannot be built by
  SwiftPM; the project is now Xcode-managed (XcodeGen → .xcodeproj).

### Migration from v0.2.x

If you were on v0.2.x, the upgrade is structural:

1. `brew upgrade --cask simulatorcamera` (cask now points at the new app)
2. Open SimulatorCamera, click Activate, click Allow in System Settings
3. **Remove `SimulatorCameraClient` from your iOS app's Package.swift**
4. **Remove all `import SimulatorCameraClient` lines from your code**
5. **Remove the `NSLocalNetworkUsageDescription` Info.plist key** (was
   the v0.2 silent-failure gotcha; no longer needed)
6. **Remove the `SimulatorCameraSession` / `SimulatorCameraView` /
   `SimulatorCaptureSession` usage** — your existing
   `AVCaptureSession`-based code is now the path.

Net effect: the migration deletes code from your app rather than adding it.

## [0.2.0] — 2026-04-15

### Added
- **Full `AVCaptureSession` drop-in shim.** New `SimulatorCaptureSession`, `SimulatorCaptureDevice`, `SimulatorCaptureDeviceInput` types let existing camera-setup code port by prefixing each AVFoundation type with `Simulator`.
- `SimulatorCamera` top-level facade (`configure(host:port:)`, `start()`, `stop()`, `isActive`) — one entry point for the whole SDK.
- Internal `_Router` fan-out: a single network session drives N `SimulatorCameraOutput` / preview sinks.
- **Mac Camera source** in the companion app (`AVCaptureDevice.default(for: .video)`) — pick between video file and live Mac webcam from the server UI.
- Homebrew cask formula + tap instructions for one-line install of the Mac companion app.
- `scripts/build-release.sh` — archive, codesign, notarize, staple, and package the Mac app as both `.dmg` and `.zip`.
- `.github/workflows/release.yml` — tag-driven release: builds artifacts, drafts GitHub Release, uploads the `.dmg` and `.zip`.
- `RELEASING.md` runbook.
- `FUNDING.yml` for GitHub Sponsors / Buy Me a Coffee.

### Changed
- README: Homebrew install path, donation badge, v0.2 feature matrix, new "Full AVCaptureSession drop-in" usage block.
- Package is stable on iOS 16 / macOS 13; no source-breaking changes from 0.1.0 — existing `SimulatorCameraSession` / `SimulatorCameraOutput` code compiles unchanged.

### Fixed
- `SimulatorCameraOutput`: replaced broken `objc_setAssociatedObject(_, String, …)` wiring with a typed `routerToken` — package now compiles cleanly.

## [0.1.0] — 2026-04-14

First public alpha.

### Added
- Monorepo layout with root SwiftPM `Package.swift`.
- `FrameSource` protocol + `SimulatorCameraSession` + `SimulatorCameraPreviewView`.
- Reference SCMF codec and stream decoder.
- Mac companion app with test-pattern source.
- iOS demo app with Vision rectangle-detection hook.
- Protocol spec ([docs/PROTOCOL.md](docs/PROTOCOL.md)), architecture overview, roadmap.
