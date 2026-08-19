#!/bin/bash
#
# Clean reinstall, for the case where an OLDER version of the app was previously
# installed on this Mac.
#
# Why an older install breaks the new one: macOS stores a privacy grant against
# the app's code identity, not its name. The old copy was granted under its own
# identity, and that entry survives the old app being replaced. The Accessibility
# list then shows "WindowSwitcher" (often already switched on, sometimes twice)
# while applying to an identity the new build does not have — so the new copy is
# never trusted no matter how many times you toggle it. Replacing the app cannot
# fix that; the stale entry has to be removed first, which is what this does.
#
# Usage:  ./reinstall.sh          list what will be removed, ask, then reinstall
#         ./reinstall.sh --yes    skip the confirmation
#         ./reinstall.sh --keep-settings-only
#                                 as above but never touches your shortcut prefs
#                                 (this is the default; the flag is a no-op kept
#                                 for clarity)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="com.example.windowswitcher"
ASSUME_YES=0
for arg in "$@"; do
	case "$arg" in
		--yes|-y) ASSUME_YES=1 ;;
		--keep-settings-only) : ;;   # default behaviour; accepted for clarity
		*) echo "Unknown option: $arg" >&2; exit 1 ;;
	esac
done

echo "==> Quitting any running copy"
osascript -e 'tell application "WindowSwitcher" to quit' >/dev/null 2>&1 || true
pkill -x WindowSwitcher >/dev/null 2>&1 || true
sleep 1

# ---------------------------------------------------------------------------
# Find every copy on disk. Spotlight knows about most of them; the explicit
# locations catch copies in folders Spotlight skips, and any left behind by App
# Translocation. The repo's own build/ directory is excluded — it is rebuilt
# below, so removing it would only be noise.
# ---------------------------------------------------------------------------
echo "==> Looking for existing copies"
FOUND=()
while IFS= read -r path; do
	[ -n "$path" ] || continue
	case "$path" in
		"$ROOT"/build/*) continue ;;
	esac
	FOUND+=("$path")
done < <(
	{
		mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true
		for dir in /Applications "$HOME/Applications" "$HOME/Downloads" "$HOME/Desktop"; do
			[ -d "$dir" ] && find "$dir" -maxdepth 2 -name "WindowSwitcher.app" -print 2>/dev/null || true
		done
	} | sort -u
)

if [ "${#FOUND[@]}" -eq 0 ]; then
	echo "    none found"
else
	printf '    %s\n' "${FOUND[@]}"
fi

echo
echo "This will:"
if [ "${#FOUND[@]}" -gt 0 ]; then
	echo "  * delete the ${#FOUND[@]} app copy/copies listed above"
fi
echo "  * clear this Mac's Accessibility and Screen Recording entries for $BUNDLE_ID"
echo "  * rebuild and install a fresh copy into /Applications, then launch it"
echo "  * leave your shortcut settings alone"
echo

if [ "$ASSUME_YES" -ne 1 ]; then
	printf 'Continue? [y/N] '
	read -r reply
	case "$reply" in
		[yY]|[yY][eE][sS]) ;;
		*) echo "Aborted — nothing was changed."; exit 0 ;;
	esac
fi

if [ "${#FOUND[@]}" -gt 0 ]; then
	echo "==> Removing old copies"
	for path in "${FOUND[@]}"; do
		rm -rf "$path" && echo "    removed $path"
	done
fi

# ---------------------------------------------------------------------------
# The actual fix: drop the permission entries tied to the old identity. This is
# the step that cannot be done by reinstalling, and the reason a reinstall alone
# never helped.
# ---------------------------------------------------------------------------
echo "==> Clearing stale permission entries"
for service in Accessibility ScreenCapture; do
	if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
		echo "    cleared $service"
	else
		echo "    !! could not clear $service automatically."
		echo "       Open System Settings > Privacy & Security > ${service}, select every"
		echo "       WindowSwitcher row, and remove it with the '-' button before continuing."
	fi
done

# Forget the recorded identity so the fresh install treats this as a first run.
defaults delete "$BUNDLE_ID" lastSeenDesignatedRequirement >/dev/null 2>&1 || true

echo "==> Building and installing"
"$ROOT/build.sh" install

# Rebuild the Launch Services record, so Finder and Spotlight point at the new
# bundle (and show its icon) instead of the one that was just deleted.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f /Applications/WindowSwitcher.app || true

cat <<'MSG'

==> Done.

Now grant the permission once, on a clean slate:

  1. The setup window should be open. Click "Open Settings" next to Accessibility.
  2. Switch Window Switcher on. There should be exactly ONE row for it — if you
     see two, the old entry was not cleared; remove both with "-" and try again.
  3. Back in the setup window, click "Restart App".

The switcher becomes active as soon as Accessibility is granted. If it still is
not recognised, run ./build.sh doctor and check the launch diagnostics:

  log show --last 5m --predicate 'subsystem == "com.example.windowswitcher"' --info

MSG
