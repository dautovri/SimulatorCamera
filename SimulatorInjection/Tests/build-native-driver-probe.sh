#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="${1:?usage: build-native-driver-probe.sh /path/to/small-hello/app/Sources/Media}"
OUT="$ROOT/build/NativeDriverProbe.app"
mkdir -p "$OUT" "$ROOT/build/evidence"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDKROOT="$SDK" xcrun --sdk iphonesimulator swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
  "$SOURCE"/Adapters/*.swift "$SOURCE"/Service/*.swift "$SOURCE"/Types/*.swift "$SOURCE"/UI/*.swift \
  "$ROOT/SimulatorInjection/Tests/NativeDriverProbe.swift" -o "$OUT/NativeDriverProbe"
shasum -a 256 "$SOURCE"/Adapters/*.swift "$SOURCE"/Service/*.swift "$SOURCE"/Types/*.swift "$SOURCE"/UI/*.swift > "$ROOT/build/evidence/native-source-hashes.txt"
cp "$ROOT/build/RecordingProbe.app/Info.plist" "$OUT/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.dautov.NativeDriverProbe' "$OUT/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable NativeDriverProbe' "$OUT/Info.plist"
codesign -s - --force "$OUT"
echo "$OUT"
