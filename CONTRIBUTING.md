# Contributing

Thanks for considering a contribution! SimulatorCamera is small and opinionated — we keep it that way.

## Ground rules

1. **No private APIs.** Ever. Every symbol we import must be public and documented in Apple's SDK.
2. **Zero SDK.** Consuming iOS apps must never need to import, link, or configure anything. If a change would require app-side code, it's the wrong change.
3. **The extension is the product.** `SimulatorCameraExtension` must keep serving frames when the container app quits. Don't move state into the app that the extension needs.
4. **The camera contract is a contract.** Changes to [`Shared/CameraContract.swift`](Shared/CameraContract.swift) (frame geometry, stream names, custom properties, status encoding) affect the app, the extension, and `simcamctl` simultaneously — update all three, keep `Tests/CameraContractTests.swift` green, and note it in the CHANGELOG.

## Dev setup

Requires macOS 14+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
git clone https://github.com/dautovri/SimulatorCamera.git
cd SimulatorCamera
xcodegen generate                 # regenerate .xcodeproj from project.yml
open SimulatorCamera.xcodeproj
```

There is **no Swift Package** — `swift build` / `swift test` do not work
here. System extensions cannot be built by SwiftPM, so the project is
Xcode-managed via `project.yml`. Edit `project.yml`, not the `.xcodeproj`.

Testing a locally-built extension requires it to be **signed and run from
`/Applications`** — macOS refuses to activate system extensions from
arbitrary locations. See [`scripts/build-signed-dev.sh`](scripts/build-signed-dev.sh)
and enable developer mode:

```bash
systemextensionsctl developer on
```

## Pull requests

- Branch off `main`.
- Keep PRs small and focused. One feature / bug per PR.
- Run `swiftformat .` and `swiftlint` before pushing (configs in the repo root).
- Update [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]`.

## Filing issues

Use the issue templates. For bugs, include:
- macOS + Xcode + iOS Simulator versions
- Output of `simcamctl status` and `systemextensionsctl list`
- Whether the extension was approved in System Settings → General → Login Items & Extensions
- Console / `os_log` output from both the app and the extension

## Code of conduct

Be decent. We follow the [Contributor Covenant](https://www.contributor-covenant.org/).
