#!/usr/bin/env bash
#
# smoke-test.sh — local end-to-end sanity check.
#
# 1. Regenerates the Xcode project from project.yml and builds it.
#    (This project is NOT a Swift Package — SwiftPM cannot build system
#    extensions, so there is no `swift build` / `swift test` step.)
# 2. Verifies the extension is registered with macOS.
# 3. Pushes a known source via simcamctl and reports stream status.
# 4. Opens the iOS Simulator so you can confirm frames arrive.
#
# Run from the repo root:
#   ./scripts/smoke-test.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

say() { printf "\n\033[1;34m▶︎\033[0m %s\n" "$*"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m!\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m✗\033[0m %s\n" "$*"; exit 1; }

say "swift --version"
swift --version || die "Swift toolchain not found — install Xcode command line tools."

command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found — brew install xcodegen"

say "xcodegen generate"
xcodegen generate
ok "SimulatorCamera.xcodeproj regenerated from project.yml."

say "xcodebuild (Debug)"
xcodebuild -project SimulatorCamera.xcodeproj \
    -scheme SimulatorCamera \
    -configuration Debug \
    -derivedDataPath .build/mac \
    build | tail -5
ok "Container app + extension build."

say "systemextensionsctl list"
if systemextensionsctl list | grep -q "com.dautov.SimulatorCamera.Extension"; then
    ok "Extension is registered with macOS."
else
    warn "Extension not registered yet."
    warn "Launch SimulatorCamera.app once and click Activate, then approve in"
    warn "System Settings → General → Login Items & Extensions."
fi

SIMCAMCTL=".build/mac/Build/Products/Debug/simcamctl"
if [[ -x "$SIMCAMCTL" ]]; then
    say "simcamctl ping"
    "$SIMCAMCTL" ping || warn "Extension not responding — is it activated?"

    say "simcamctl set-source --qr (smoke fixture)"
    warn "Opening the sink stream may prompt for camera access for this terminal."
    "$SIMCAMCTL" set-source --qr "https://example.com/smoke-test" || \
        warn "Could not push QR source."

    say "simcamctl status"
    "$SIMCAMCTL" status || true
else
    warn "simcamctl not built at $SIMCAMCTL"
fi

say "Booting iOS Simulator"
SIM_NAME="${SIM_NAME:-iPhone 16}"
xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
open -a Simulator
ok "Simulator up."

cat <<'EOF'

---------------------------------------------------------------
Next manual steps:
  1. Run any camera app on the Simulator (Xcode 16+ required). The
     extension only reports "stream running: yes" while such a client
     is actually capturing from the virtual camera.
  2. AVCaptureDevice.default(for: .video) should return
     "SimulatorCamera Virtual" and deliver the QR frame pushed above.

If the camera is missing in the Simulator:
  - Confirm approval in System Settings → General → Login Items
    & Extensions.
  - Confirm `simcamctl status` shows "stream running: yes".
  - Older Simulator runtimes (pre-Xcode 16) do not enumerate host
    virtual cameras at all.
---------------------------------------------------------------
EOF
