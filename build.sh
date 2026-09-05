#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/HueShift.app"

rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc \
  "$PROJECT_DIR/Sources/main.swift" \
  -o "$APP/Contents/MacOS/HueShift" \
  -framework Cocoa \
  -framework CoreImage \
  -framework ScreenCaptureKit \
  -framework AVFoundation \
  -target arm64-apple-macos15.0 \
  -O

cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
xattr -cr .
open "$APP"
