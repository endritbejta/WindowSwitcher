#!/bin/bash
#
# Builds WindowSwitcher.app from the Swift sources with swiftc (no Xcode project
# required) and assembles a proper .app bundle so macOS TCC can grant it
# Accessibility and Screen Recording permissions.
#
# Usage:  ./build.sh          build the app into ./build/WindowSwitcher.app
#         ./build.sh run      build, then launch it
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/WindowSwitcher.app"
MACOS_DIR="$APP/Contents/MacOS"
EXECUTABLE="$MACOS_DIR/WindowSwitcher"

# Build for the machine's native architecture. Minimum macOS 14 for the
# ScreenCaptureKit screenshot API used to render window previews.
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"

echo "==> Compiling ($TARGET)"
rm -rf "$APP"
mkdir -p "$MACOS_DIR"

# swiftc compiles all sources into one executable. main.swift must be present
# for the top-level entry point.
swiftc \
	-O \
	-target "$TARGET" \
	-framework Cocoa \
	-framework SwiftUI \
	-framework ApplicationServices \
	-framework CoreGraphics \
	-framework ScreenCaptureKit \
	-o "$EXECUTABLE" \
	"$ROOT"/Sources/*.swift

echo "==> Assembling bundle"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc code signature. A stable signature helps TCC remember the granted
# permissions; ad-hoc is fine for local use (you may need to re-grant after a
# rebuild). Replace "-" with a Developer ID for distribution.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Built: $APP"

if [[ "${1:-}" == "run" ]]; then
	echo "==> Launching"
	open "$APP"
fi
