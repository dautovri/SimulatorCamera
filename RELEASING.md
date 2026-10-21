# Releasing SimulatorCamera

This runbook cuts a signed, notarized release of the Mac companion app.

> ⚠️ **Not yet exercised.** No release has been published and no tag has
> ever been pushed — `v0.2.0` was written up in release notes but never
> tagged, which is why its documented install commands don't work. The
> public distribution channel is also still undecided (see
> [docs/ROADMAP.md](docs/ROADMAP.md#open-questions)), so the Homebrew step
> below is provisional. Validate each step the first time through, and
> don't advertise an install path in the README until it is actually live.

There is no iOS Swift Package to release — the SDK was removed in v1.0.0.

## Prereqs (one-time per machine)

- Xcode 16+ with a configured Apple ID that has Developer ID signing privileges.
- A stored `notarytool` profile so CI and local builds don't need to handle secrets inline:
  ```
  xcrun notarytool store-credentials "SimulatorCameraNotary" \
      --apple-id "you@example.com" \
      --team-id  "ABCDE12345" \
      --password "app-specific-password"
  ```
- GitHub secrets configured on the repo:
  - `MAC_CERTIFICATE_P12_BASE64`, `MAC_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`
  - `APPLE_DEVELOPER_ID`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`

## Cut a release

1. **Pick a version** (`MAJOR.MINOR.PATCH`). For 0.x we bump MINOR for new
   features, PATCH for fixes. Source of truth: `CHANGELOG.md`.

2. **Prep the repo**
   ```
   git checkout main
   git pull
   ```
   - Move `## [Unreleased]` content into a new `## [X.Y.Z] — YYYY-MM-DD`
     section in `CHANGELOG.md`.
   - Write `docs/RELEASE_NOTES_vX.Y.Z.md` (user-facing, not a dupe of the
     changelog — lead with headlines, link back to the changelog for detail).
   - Bump the cask version in `Casks/simulatorcamera.rb` and leave the
     `sha256` as a placeholder (step 5 fills it in).

3. **Local dry run**
   ```
   SKIP_NOTARIZE=1 VERSION=X.Y.Z ./scripts/build-release.sh
   open dist/
   ```
   Sanity-check the `.app` launches from the `.dmg`.

4. **Tag and push**
   ```
   git commit -am "release: vX.Y.Z"
   git tag -s vX.Y.Z -m "SimulatorCamera vX.Y.Z"
   git push origin main vX.Y.Z
   ```
   The `Release` workflow picks up the tag, builds, notarizes, and uploads
   a **draft** GitHub Release with the `.dmg`, `.zip`, and checksums.

5. **Update the Homebrew cask**
   - Grab the DMG sha256 from the Release workflow's job summary (also in
     `dist/SimulatorCamera-X.Y.Z.sha256` and the
     Release page).
   - Commit the updated `Casks/simulatorcamera.rb` to the tap repo
     (`dautovri/homebrew-tap`):
     ```
     brew bump-cask-pr \
         --version X.Y.Z \
         --sha256 <dmg-sha256> \
         dautovri/tap/simulatorcamera
     ```

6. **Publish the draft Release**
   - Double-check the release notes render.
   - Un-draft.

7. **Smoke test**
   ```
   brew update
   brew upgrade --cask simulatorcamera
   open -a SimulatorCamera
   ```
   Click **Activate** and approve in System Settings → General → Login
   Items & Extensions, then push a known source:
   ```
   simcamctl set-source --qr "https://example.com/release-check"
   simcamctl status
   ```
   Then in a throwaway iOS app on an Xcode 16+ Simulator — with **no
   imports and no project changes**:
   ```swift
   let device = AVCaptureDevice.default(for: .video)
   // → "SimulatorCamera Virtual"
   ```
   Verify frames arrive at 30 FPS.

8. **Announce**
   - Tweet / LinkedIn / /r/iOSProgramming post linking to the Release.
   - Update `docs/ROADMAP.md` by moving the just-shipped bullets into the
     "Shipped" section and drafting the next milestone.

## If something goes wrong

- **Notarization stuck.** `xcrun notarytool log <submission-id> --keychain-profile SimulatorCameraNotary` — Apple tells you exactly which rule tripped.
- **CI artifacts wrong version.** The workflow normalizes `v0.2.0 → 0.2.0`; if you see mismatched filenames the tag was probably pushed without a `v` prefix.
- **Need to yank a release.** Delete the tag, delete the Release, revert the cask commit. Existing users stay on whatever they have; Homebrew won't downgrade by default.
