#!/bin/bash
#
# Builds WindowSwitcher.app from the Swift sources with swiftc (no Xcode project
# required) and assembles a proper .app bundle so macOS TCC can grant it
# Accessibility and Screen Recording permissions.
#
# Usage:  ./build.sh            build the app into ./build/WindowSwitcher.app
#         ./build.sh run        build, then launch it from ./build
#         ./build.sh install    build, install into /Applications, launch there
#         ./build.sh doctor     report the code identity and why grants stick
#
# On the permission problem this script guards against: macOS remembers a
# privacy grant against the app's "designated requirement", a code-signing
# predicate. Sign ad-hoc and that predicate is the binary's own hash, so every
# rebuild produces an app the system considers brand new and every grant is
# silently orphaned — the toggle in System Settings stays on while the app is
# never trusted. So an ad-hoc build is a hard error here, not a warning.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/WindowSwitcher.app"
MACOS_DIR="$APP/Contents/MacOS"
EXECUTABLE="$MACOS_DIR/WindowSwitcher"
BUNDLE_ID="com.example.windowswitcher"

CERT_CN="WindowSwitcher Self-Signed"
SIGN_KEYCHAIN="$HOME/Library/Keychains/windowswitcher-signing.keychain-db"
SIGN_KC_PASS="winswitch-local"   # unlocks only the dedicated signing keychain
# Records the requirement the last build produced, so a change of identity (the
# thing that breaks grants) is reported instead of passing unnoticed.
DR_RECORD="$ROOT/.signing-identity"

COMMAND="${1:-build}"

# ---------------------------------------------------------------------------
# doctor: explain the current state without building anything.
# ---------------------------------------------------------------------------
if [[ "$COMMAND" == "doctor" ]]; then
	echo "== Signing identities available on this Mac =="
	security find-identity -p codesigning 2>/dev/null | grep -E "Developer ID Application|$CERT_CN" \
		|| echo "  (none suitable — run ./setup-signing.sh)"
	echo
	for candidate in "$APP" "/Applications/WindowSwitcher.app"; do
		[ -d "$candidate" ] || continue
		echo "== $candidate =="
		# An ad-hoc signature has no explicit requirement, so codesign prints
		# the implicit one commented out ("# designated => ..."); match both.
		codesign -d -r- "$candidate" 2>&1 | sed -n 's/^#* *designated => /  requirement: /p'
		if xattr -p com.apple.quarantine "$candidate" >/dev/null 2>&1; then
			echo "  quarantined: yes  <-- macOS will run this from a random path and lose grants"
		else
			echo "  quarantined: no"
		fi
		echo
	done
	echo "== Recorded identity from the last build =="
	if [ -f "$DR_RECORD" ]; then cat "$DR_RECORD"; else echo "  (none yet)"; fi
	exit 0
fi

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
	-framework Security \
	-o "$EXECUTABLE" \
	"$ROOT"/Sources/*.swift

echo "==> Assembling bundle"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# The app icon Finder, the Dock and Spotlight show. Rendered from the same
# artwork as the menu-bar glyph (Sources/AppIcon.swift) by a throwaway tool, so
# the two can never drift apart and no binary asset has to live in the repo.
# Must happen before signing: bundle resources are sealed into the signature.
echo "==> Generating app icon"
RESOURCES_DIR="$APP/Contents/Resources"
mkdir -p "$RESOURCES_DIR"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
swiftc -O -target "$TARGET" -framework Cocoa \
	-o "$ICON_WORK/generate-app-icon" \
	"$ROOT/Tools/main.swift" "$ROOT/Sources/AppIcon.swift"
"$ICON_WORK/generate-app-icon" "$ICON_WORK/AppIcon.iconset"
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$RESOURCES_DIR/AppIcon.icns"

# ---------------------------------------------------------------------------
# Signing. A stable code identity is what makes a permission grant survive a
# rebuild, so there is no silent fallback: without an identity the build stops.
# ---------------------------------------------------------------------------
echo "==> Signing"
DEV_ID="$(security find-identity -p codesigning 2>/dev/null \
	| sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"

if [ -n "$DEV_ID" ]; then
	# Best case: an Apple-issued identity. The requirement is pinned to the team
	# identifier, so it is identical on every machine and every rebuild.
	codesign --force --sign "$DEV_ID" --identifier "$BUNDLE_ID" \
		--options runtime --timestamp "$APP"
	echo "    signed with Developer ID: $DEV_ID"
elif security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
	[ -f "$SIGN_KEYCHAIN" ] && security unlock-keychain -p "$SIGN_KC_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
	# No --deep: the bundle has no nested code, and --deep is deprecated for
	# signing because it re-signs inner items with the outer options.
	codesign --force --sign "$CERT_CN" --identifier "$BUNDLE_ID" "$APP"
	echo "    signed with stable identity: $CERT_CN"
elif [ "${ALLOW_ADHOC:-0}" = "1" ]; then
	codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true
	echo "    !! signed AD-HOC because ALLOW_ADHOC=1."
	echo "    !! Permission grants will be lost on the next rebuild."
else
	cat >&2 <<-MSG

	!! No stable code-signing identity found, so this build was stopped.

	   Signing ad-hoc would produce an app whose permission grants macOS
	   forgets on every rebuild — the exact "I granted it but it isn't
	   recognised" failure. Set up an identity once instead:

	       ./setup-signing.sh                 create one on this Mac
	       ./setup-signing.sh import <file>   reuse the one from your other Mac

	   To reuse the identity across Macs, export it on the machine that
	   already works and import it here:

	       ./setup-signing.sh export ~/Desktop/windowswitcher-identity.p12

	   To build anyway, knowingly accepting that grants will not persist:

	       ALLOW_ADHOC=1 ./build.sh

	MSG
	exit 1
fi

# ---------------------------------------------------------------------------
# Report the requirement, and shout if it changed since the last build — that
# change is precisely what invalidates an existing grant.
# ---------------------------------------------------------------------------
CURRENT_DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^#* *designated => //p')"
echo "==> Identity: ${CURRENT_DR:-unknown}"

if [ -f "$DR_RECORD" ] && [ -n "$CURRENT_DR" ]; then
	PREVIOUS_DR="$(cat "$DR_RECORD")"
	if [ "$PREVIOUS_DR" != "$CURRENT_DR" ]; then
		cat >&2 <<-MSG

		!! The code identity CHANGED since the last build.
		     was: $PREVIOUS_DR
		     now: $CURRENT_DR
		   macOS still holds your permission grant against the old identity, so
		   this build will not be trusted until that entry is cleared. The app
		   detects this on launch and offers "Reset Permissions & Restart", or
		   you can do it yourself:

		       tccutil reset Accessibility $BUNDLE_ID

		MSG
	fi
fi
[ -n "$CURRENT_DR" ] && printf '%s\n' "$CURRENT_DR" > "$DR_RECORD"

echo "==> Built: $APP"

# ---------------------------------------------------------------------------
# install: put the app in /Applications. A stable location means macOS never
# translocates it, which is the other way a grant gets lost.
# ---------------------------------------------------------------------------
if [[ "$COMMAND" == "install" ]]; then
	DEST="/Applications/WindowSwitcher.app"
	echo "==> Installing to $DEST"
	# Quit a running copy so the bundle can be replaced underneath it.
	osascript -e 'tell application "WindowSwitcher" to quit' >/dev/null 2>&1 || true
	pkill -x WindowSwitcher >/dev/null 2>&1 || true
	sleep 1
	rm -rf "$DEST"
	cp -R "$APP" "$DEST"
	# Strip the download flag if one came along for the ride; a quarantined
	# bundle gets run from a random path and cannot hold a permission.
	xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
	echo "==> Launching $DEST"
	open "$DEST"
	exit 0
fi

if [[ "$COMMAND" == "run" ]]; then
	echo "==> Launching"
	open "$APP"
fi
