#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/RecordingProbe.app"
mkdir -p "$OUT"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun clang -fobjc-arc -fmodules -Wno-deprecated-declarations -Wno-incompatible-pointer-types \
  -isysroot "$SDK" -target arm64-apple-ios16.0-simulator \
  -framework UIKit -framework AVFoundation -framework CoreMedia \
  "$ROOT/SimulatorInjection/Tests/RecordingProbe.m" -o "$OUT/RecordingProbe"
cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.dautov.RecordingProbe</string>
<key>CFBundleExecutable</key><string>RecordingProbe</string>
<key>CFBundleName</key><string>RecordingProbe</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>NSCameraUsageDescription</key><string>Validate simulator movie recording.</string>
<key>NSMicrophoneUsageDescription</key><string>Validate microphone sound in simulator movies.</string>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign -s - --force "$OUT"
echo "$OUT"
