#!/usr/bin/env bash
#
# build-release.sh — archive, codesign, notarize, staple, package the
#                    SimulatorCamera Mac app + bundled Camera Extension
#                    for a GitHub Release.
#
# Produces:
#   dist/SimulatorCamera-<VERSION>.dmg
#   dist/SimulatorCamera-<VERSION>.zip
#   dist/SimulatorCamera-<VERSION>.sha256
#
# Required env vars:
#   APPLE_DEVELOPER_ID      "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID                Apple ID used for notarization
#   APPLE_APP_PASSWORD      app-specific password for notarytool
#   APPLE_TEAM_ID           10-char team ID
#
# Optional env vars:
#   VERSION                 e.g. 1.0.0  (else read from git tag)
#   KEYCHAIN_PROFILE        reuse a stored notarytool profile (takes precedence)
#   SKIP_NOTARIZE=1         for local/dev builds — skips notarytool + stapler
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0-dev)}"
APP_NAME="SimulatorCamera"
SCHEME="SimulatorCamera"
PROJECT="SimulatorCamera.xcodeproj"
BUILD_DIR="$REPO_ROOT/build"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# ── Pre-flight ──────────────────────────────────────────────────────────────

if [[ ! -d "$PROJECT" ]]; then
    echo "ERROR: $PROJECT not found. Run 'xcodegen generate' first." >&2
    exit 1
fi

# Regenerate from project.yml in case anything changed.
if command -v xcodegen >/dev/null 2>&1; then
    echo "▶︎ xcodegen generate"
    xcodegen generate
fi

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ── Archive ─────────────────────────────────────────────────────────────────
# xcodebuild archive packages the container app + the bundled Camera
# Extension. Xcode's signing pipeline handles inside-out signing of the
# nested .systemextension automatically when CODE_SIGN_STYLE=Automatic and
# DEVELOPMENT_TEAM is set.

# Optional: let xcodebuild create missing provisioning profiles via an App Store
# Connect API key (ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID).
AUTH_ARGS=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
    AUTH_ARGS=(-allowProvisioningUpdates
        -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "${ASC_KEY_ID:?ASC_KEY_ID required}"
        -authenticationKeyIssuerID "${ASC_ISSUER_ID:?ASC_ISSUER_ID required}")
fi

echo "▶︎ Archiving $APP_NAME $VERSION"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}" \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    archive 2>&1 | (xcpretty --simple || cat)

# ── Export with Developer ID ────────────────────────────────────────────────

echo "▶︎ Exporting .app with Developer ID signing"
# Optional manual signing: set PROFILE_HOST / PROFILE_EXT to the names of installed
# Developer ID provisioning profiles for the app and the Camera Extension.
SIGN_STYLE="automatic"
PROFILE_MAP=""
if [[ -n "${PROFILE_HOST:-}" && -n "${PROFILE_EXT:-}" ]]; then
    SIGN_STYLE="manual"
    PROFILE_MAP="<key>signingCertificate</key><string>Developer ID Application</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>com.dautov.SimulatorCamera</key><string>${PROFILE_HOST}</string>
        <key>com.dautov.SimulatorCamera.Extension</key><string>${PROFILE_EXT}</string>
    </dict>"
fi
cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>                  <string>developer-id</string>
    <key>teamID</key>                  <string>${APPLE_TEAM_ID:-}</string>
    <key>signingStyle</key>            <string>${SIGN_STYLE}</string>
    <key>stripSwiftSymbols</key>       <true/>
    ${PROFILE_MAP}
</dict>
</plist>
EOF

xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} 2>&1 | (xcpretty --simple || cat)

APP_BUNDLE="$EXPORT_PATH/$APP_NAME.app"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: exportArchive did not produce $APP_BUNDLE" >&2
    exit 1
fi

# ── Verify signing chain inside-out ─────────────────────────────────────────

echo "▶︎ Verifying signature chain"

APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
EXTENSION_BUNDLE="$APP_BUNDLE/Contents/Library/SystemExtensions/$APP_BUNDLE_ID.Extension.systemextension"
if [[ ! -d "$EXTENSION_BUNDLE" ]]; then
    echo "ERROR: bundled extension not found at $EXTENSION_BUNDLE" >&2
    exit 1
fi

# Outer .app must have Developer ID signature.
grep -q "Authority=Developer ID Application" <(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1) \
    || { echo "ERROR: outer .app not signed with Developer ID" >&2; exit 1; }

# Nested extension must too.
grep -q "Authority=Developer ID Application" <(codesign -dv --verbose=4 "$EXTENSION_BUNDLE" 2>&1) \
    || { echo "ERROR: nested extension not signed with Developer ID" >&2; exit 1; }

echo "✓ both binaries signed with Developer ID"

# ── Notarize ────────────────────────────────────────────────────────────────

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    echo "▶︎ Notarizing (typically 1-3 minutes for first-time submission)"
    ZIP_FOR_NOTARY="$BUILD_DIR/$APP_NAME-notary.zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_FOR_NOTARY"

    if [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIP_FOR_NOTARY" \
            --keychain-profile "$KEYCHAIN_PROFILE" \
            --wait
    else
        xcrun notarytool submit "$ZIP_FOR_NOTARY" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait
    fi

    echo "▶︎ Stapling"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
else
    echo "▶︎ SKIP_NOTARIZE set — skipping notarization + stapler"
fi

# ── Package outputs ─────────────────────────────────────────────────────────

echo "▶︎ Packaging .zip"
ZIP_OUT="$DIST_DIR/SimulatorCamera-$VERSION.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_OUT"

echo "▶︎ Packaging .dmg"
DMG_OUT="$DIST_DIR/SimulatorCamera-$VERSION.dmg"
hdiutil create \
    -volname "SimulatorCamera $VERSION" \
    -srcfolder "$APP_BUNDLE" \
    -ov -format UDZO \
    "$DMG_OUT"

# Sign the DMG itself (required for notarization to confer Gatekeeper acceptance
# on the DMG — not just on the .app inside).
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    codesign --sign "$APPLE_DEVELOPER_ID" --timestamp "$DMG_OUT"
    if [[ -n "${KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG_OUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    else
        xcrun notarytool submit "$DMG_OUT" \
            --apple-id "${APPLE_ID:-}" \
            --password "${APPLE_APP_PASSWORD:-}" \
            --team-id "${APPLE_TEAM_ID:-}" \
            --wait
    fi
    xcrun stapler staple "$DMG_OUT"
fi

echo "▶︎ Computing checksums"
(
    cd "$DIST_DIR"
    shasum -a 256 \
        "SimulatorCamera-$VERSION.zip" \
        "SimulatorCamera-$VERSION.dmg" \
        > "SimulatorCamera-$VERSION.sha256"
)

# ── Final verification ──────────────────────────────────────────────────────

echo "▶︎ Final Gatekeeper check"
if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
    spctl -a -t open --context context:primary-signature -v "$DMG_OUT" \
        || { echo "ERROR: DMG failed Gatekeeper assessment" >&2; exit 1; }
    echo "✓ DMG accepted by Gatekeeper"
fi

echo
echo "✅ Done."
ls -lh "$DIST_DIR"
