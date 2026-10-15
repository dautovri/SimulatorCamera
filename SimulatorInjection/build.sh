#!/bin/zsh
# Builds libSimCamInject.dylib for the iOS Simulator (arm64 + x86_64).
# Usage: SimulatorInjection/build.sh [output-dir]   (default: build/SimulatorInjection)
set -euo pipefail
# When run from the Mac app's build phase, drop the macOS build settings.
unset SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET ARCHS 2>/dev/null || true
HERE=${0:A:h}
OUT=${1:-$HERE/../build/SimulatorInjection}
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun clang -dynamiclib -fobjc-arc -fmodules -O2 -Wall -Wno-unused-variable \
  -isysroot "$SDK" -arch arm64 -arch x86_64 -mios-simulator-version-min=16.0 \
  -framework Foundation -framework AVFoundation -framework CoreImage -framework CoreMedia \
  -framework CoreVideo -framework UIKit -framework QuartzCore \
  -install_name @rpath/libSimCamInject.dylib \
  -o "$OUT/libSimCamInject.dylib" "$HERE/SimCamInject.m"
codesign -s - --force "$OUT/libSimCamInject.dylib" >/dev/null
echo "$OUT/libSimCamInject.dylib"
