# SimulatorCamera v1.1.0

Your Mac's camera, in the iOS Simulator. Free and open.

SimulatorCamera is a macOS companion app that feeds a virtual camera into the
iOS Simulator. Your app imports nothing and needs no `#if targetEnvironment(simulator)`
branches.

## Highlights

- **Virtual camera for the Simulator.** A Camera Extension registers
  "SimulatorCamera Virtual" on the Mac; a small injected library
  (`libSimCamInject.dylib`) brings it into Xcode 26 / 27 simulators, where
  `AVCaptureDevice` otherwise lists no cameras at all. Video data output,
  preview layers, QR metadata and photo capture are supported.
- **Five sources:** test pattern, Mac camera, video file, static image and a QR
  code generator, all normalized to 1280x720 BGRA at 30 fps.
- **Movie recording with sound.** `AVCaptureMovieFileOutput` records H.264 + AAC
  QuickTime files, with rotation and mirroring honored.
- **`simcamctl` for CI and agents.** `simcamctl feed --qr "TEXT" | --image PATH |
  --pattern | --camera`, plus `status` and `ping`.
- **Reliable frame transport.** Frames now travel over CoreMediaIO sink streams
  instead of a private XPC listener, which never worked end to end.

## Install

Download `SimulatorCamera-1.1.0.dmg`, drag the app to `/Applications` and open it.
The release is signed with a Developer ID and notarized; macOS only activates the
system extension for such builds (or for apps in `/Applications` with system
extension developer mode on). Click **Activate** and approve in System Settings →
General → Login Items & Extensions.

```bash
brew install --cask dautovri/tap/simulatorcamera   # once the tap is updated
```

Then load the injection library into your Simulator app. In Xcode: *Edit Scheme ›
Run › Arguments › Environment Variables*, add `DYLD_INSERT_LIBRARIES` =
`/Applications/SimulatorCamera.app/Contents/Resources/libSimCamInject.dylib`.
See the [README](../README.md#ios-simulator-apps-xcode-2627).

## Requirements

macOS 14+, Apple silicon, Xcode 16+.

## Known limitations

- Barcode types other than QR, depth data and multi-cam are not supported.
- Frames are exchanged through `/private/tmp/SimulatorCamera/frame.bin`.
- Building from source needs your own Developer ID / notarization to activate the
  extension on a Mac with SIP enabled (see [issue #6](https://github.com/dautovri/SimulatorCamera/issues/6)).

Full detail: [CHANGELOG.md](../CHANGELOG.md).
