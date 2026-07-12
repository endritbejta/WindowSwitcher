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

# Prefer the stable self-signed identity created by ./setup-signing.sh: it gives
# the app a constant code identity, so macOS remembers Accessibility / Screen
# Recording grants across rebuilds. Falls back to ad-hoc if it isn't set up.
echo "==> Signing"
CERT_CN="WindowSwitcher Self-Signed"
SIGN_KEYCHAIN="$HOME/Library/Keychains/windowswitcher-signing.keychain-db"
SIGN_KC_PASS="winswitch-local"   # unlocks only the dedicated signing keychain
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
	[ -f "$SIGN_KEYCHAIN" ] && security unlock-keychain -p "$SIGN_KC_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
	codesign --force --deep --sign "$CERT_CN" --identifier com.example.windowswitcher "$APP"
	echo "    signed with stable identity: $CERT_CN"
else
	codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
	echo "    signed ad-hoc — run ./setup-signing.sh once so grants persist across rebuilds"
fi

echo "==> Built: $APP"

if [[ "${1:-}" == "run" ]]; then
	echo "==> Launching"
	open "$APP"
fi
