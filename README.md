# Window Switcher

A lightweight macOS utility that replaces the app-only Command+Tab with a
**Windows-style Alt+Tab** that cycles through **individual windows**.

Each window — including multiple windows of the same app — is its own entry,
shown with a live thumbnail and the app icon.

## Features

- **Per-window switching**, not per-app — three Chrome windows are three entries.
- **Two-window toggle** — a quick tap flips between your two most recent windows,
  just like Windows Alt+Tab (recently-used order by default; a *Fixed* mode that
  keeps tiles in place is available in Settings).
- **Hold-and-release gesture** — cycle while the modifier is down, commit on release.
- **Rebindable shortcut** (Command / Option / Control × Tab / Backtick) via a
  native Settings window — Command+Tab by default, replacing the system's own
  app switcher while the tap is active.
- **Live thumbnails** via ScreenCaptureKit, with the app icon and a subtle
  highlighted selection.
- **Native SwiftUI overlay** with system materials — automatic Light/Dark mode.
- **Low overhead** — nothing runs while idle; windows and previews are captured
  only while the switcher is open.
- **Background agent** — no Dock icon, just a menu-bar item.

## Requirements

macOS 14 or later, and the Xcode command-line tools (`xcode-select --install`)
to build.

## Installation

```bash
git clone https://github.com/endritbejta/WindowSwitcher.git
cd WindowSwitcher
./setup-signing.sh     # once per Mac
./build.sh install     # build, install into /Applications, launch
```

On first launch a setup window asks for the permissions described under
[Permissions](#permissions). Grant Accessibility and the switcher becomes active
immediately.

Install into `/Applications` rather than running from `Downloads` or the Desktop.
macOS quarantines an app downloaded to those locations and may run it from a
randomised temporary path, which prevents any permission grant from sticking.

If a previous version of the app was installed on this Mac, use `./reinstall.sh`
instead of `./build.sh install` — see
[Upgrading over an older install](#upgrading-over-an-older-install).

## Usage

The app has no window of its own. It lives in the menu bar and waits for the
shortcut.

**To switch windows**, using the default Command+Tab binding:

| Action | Keys |
|---|---|
| Open the switcher and step forward | Hold **Command**, press **Tab** |
| Step backward | Hold **Command**, press **Shift+Tab** |
| Switch to the selected window | Release **Command** |
| Cancel without switching | Press **Escape** while the switcher is open |
| Pick a window directly | Click its tile |

A **quick tap** of Command+Tab — press and release without pausing — flips
straight to your previous window, so tapping repeatedly toggles between the two
windows you use most. Holding Command keeps the overlay open so you can keep
stepping through the list.

The switcher lists every on-screen window across all running applications,
front-to-back. Minimised and hidden windows are not included, and system chrome
(the Dock, menu-bar extras, notifications, wallpaper) and small utility panels are
filtered out.

### Menu bar

Click the menu-bar icon for:

- **Status** — whether the switcher is active, and the shortcut it is bound to.
- **Settings…** (⌘,) — change the shortcut and window ordering.
- **Grant Permissions…** and **Reset Permissions & Restart** — shown only when
  the switcher is not running; see [Troubleshooting](#troubleshooting).
- **Quit**.

### Settings

Open **Settings…** from the menu-bar item:

- **Modifier** — Command (default), Option, or Control.
- **Trigger key** — Tab or Backtick (`` ` ``).
- **Window order** — *Recently used* (default; last-used window first, so a quick
  tap toggles between your two most recent windows) or *Fixed* (tiles never move).

Changes persist and take effect on the next keystroke — the hot-key handler reads
the binding live, so nothing needs restarting.

Choosing **Command** makes the app take over the system's own Command+Tab app
switcher while it is running, because the switcher swallows the event.

## Permissions

macOS requires your approval for the APIs the switcher uses. The setup window
polls until they are granted and starts the switcher as soon as it can.

| Permission | Required? | Used for |
|---|---|---|
| **Accessibility** | Yes | Reading the shortcut (a `CGEvent` tap) and raising the selected window |
| **Screen Recording** | No | Live window thumbnails and window titles |

Only **Accessibility** is required — the switcher starts the moment it is
granted. Without **Screen Recording** the switcher still works, showing app icons
instead of live thumbnails.

A freshly-granted permission usually needs a relaunch to take effect, because
macOS caches the previous state inside the running process. The setup window's
**Restart App** button does this.

## Troubleshooting

### The permission is switched on, but the app says it is not

macOS does not record a privacy grant against an app's name. It records it
against the app's **designated requirement**, a code-signing predicate. If that
predicate changes, the existing grant belongs to what macOS treats as a different
app: the switch still reads as on in System Settings while the app is never
trusted, and toggling it again has no effect.

Three things change the predicate. The app detects all three at launch and offers
the corresponding repair rather than asking you to toggle the switch again:

| Cause | Symptom | Repair |
|---|---|---|
| **App Translocation** — a quarantined app is run from a randomised temporary path | The grant never survives a quit | **Move to Applications** |
| **Changed code identity** — a new signing certificate, or an ad-hoc rebuild | The switch is on, the app disagrees | **Reset Permissions & Restart** |
| **Ad-hoc signature** — the identity is pinned to the binary's hash | The grant is lost on every rebuild | `./setup-signing.sh`, then rebuild |

**Reset Permissions & Restart** is available from the menu-bar menu and from the
setup window whenever Accessibility is missing. It clears the app's permission
entries and relaunches, so the grant can be given again from a clean slate.

### Upgrading over an older install

An older copy of the app was granted permission under *its* code identity, and
that entry outlives the app being replaced. The Accessibility list then shows
Window Switcher — often already switched on, sometimes listed twice — while
applying to an identity the new build does not have. Reinstalling alone does not
help, because the stale entry is the problem, not the app.

```bash
./reinstall.sh
```

This quits any running copy, finds and removes older copies on disk, clears the
Accessibility and Screen Recording entries for the bundle, then builds and
installs a fresh copy into `/Applications`. It lists what it will delete and asks
for confirmation before changing anything, and leaves your settings alone.

To clear the entries by hand instead:

```bash
tccutil reset Accessibility com.example.windowswitcher
tccutil reset ScreenCapture com.example.windowswitcher
```

### Diagnosing

`./build.sh doctor` reports the signing identities available, the designated
requirement of each installed copy, and whether either is quarantined.

The setup window's **Copy Details** button copies the bundle path, signing kind
and designated requirement. The same facts are logged at every launch:

```bash
log show --last 5m --predicate 'subsystem == "com.example.windowswitcher"' --info
```

`./build.sh` prints the identity on every build and warns when it differs from
the previous build, since that change is what invalidates an existing grant.

## Building from source

```bash
./build.sh install
```

`build.sh` compiles `Sources/*.swift` with `swiftc` into
`build/WindowSwitcher.app`, generates the app icon, and signs the bundle. No
Xcode project is involved.

| Command | What it does |
|---|---|
| `./build.sh` | Build into `build/WindowSwitcher.app` |
| `./build.sh run` | Build, then launch from `build/` |
| `./build.sh install` | Build, install into `/Applications`, launch from there |
| `./build.sh doctor` | Report the code identity and anything that would break grants |
| `./reinstall.sh` | Clean reinstall over a previous version |
| `./setup-signing.sh` | Create the stable signing identity for this Mac |
| `./setup-signing.sh status` | Show the identity and the requirement it produces |

### Signing

Because macOS ties a permission grant to the app's code identity, the app needs a
**stable** one. An ad-hoc signature (`codesign --sign -`) is pinned to the
binary's own hash and changes on every rebuild, so `build.sh` refuses to produce
one rather than handing you a build that silently forgets its permissions. Set
`ALLOW_ADHOC=1` to override, accepting that grants will not persist.

`setup-signing.sh` creates a self-signed certificate in a dedicated keychain,
giving the app a constant identity so a grant given once survives every future
rebuild. If a **Developer ID** identity is present, `build.sh` prefers it
automatically — that is stable across machines with no further setup.

### Building on more than one Mac

The certificate is what the grant is pinned to, so every Mac must sign with the
**same** certificate. Generating a fresh one per machine produces a different
identity on each, and the grant does not carry over. Export the identity from one
Mac and import it on the other:

```bash
# on the first Mac
./setup-signing.sh export ~/Desktop/ws-identity.p12

# on the second, after copying the file across
./setup-signing.sh import ~/Desktop/ws-identity.p12
./build.sh install
```

Delete the `.p12` afterwards. It is a signing key: anything signed with it
inherits this app's Accessibility permission, which is why it is deliberately not
committed to this repository. Use `./setup-signing.sh status` on both Macs to
confirm the requirements match.

## How it works

| Concern | Approach | File |
|---|---|---|
| Discover all real windows | `CGWindowListCopyWindowInfo`, filtered to layer‑0, visible, non‑system windows | `WindowEnumerator.swift` |
| Window ordering | Fixed (stable positions) or recently‑used; own list seeded from z‑order | `WindowOrderManager.swift` |
| Global shortcut, and detecting modifier **release** | `CGEvent` tap on keyDown + flagsChanged | `HotKeyManager.swift` |
| Focus one specific window | Accessibility API + `_AXUIElementGetWindow` to match by CGWindowID | `WindowActivator.swift` |
| Live previews | On‑demand ScreenCaptureKit stills rendered at preview size, off the main thread | `ThumbnailProvider.swift` |
| Overlay UI | SwiftUI grid in a non‑activating `NSPanel`, system materials for Light/Dark | `SwitcherView.swift`, `SwitcherPanel.swift` |
| Orchestration | Wires key events → selection → activation | `SwitcherController.swift` |
| Permissions & onboarding | Preflight/request, deep links to Settings, and repairs for a grant that cannot stick | `PermissionsManager.swift`, `AppIdentity.swift`, `PermissionSetup.swift`, `OnboardingWindow.swift` |
| Rebindable shortcut | Persisted modifier + trigger key, read live by the tap | `AppSettings.swift`, `SettingsWindow.swift` |
| Lifecycle / menu bar | Accessory app, status item | `AppDelegate.swift`, `main.swift` |

### Design notes

- **Why an event tap** rather than a Carbon hot-key: only the raw event stream
  tells us when the modifier is *released*, which is how the Windows gesture commits.
- **Why a non-activating panel**: showing the overlay must not steal focus from
  the app you're holding the modifier over, or releasing it couldn't end the
  gesture cleanly.
- **Why `_AXUIElementGetWindow`**: macOS has no public "focus this CGWindowID"
  call. This private-but-stable helper maps an Accessibility element to its
  CGWindowID so we can raise the exact window even when several share a title.
- **Low overhead**: nothing polls while idle. Windows are enumerated and
  thumbnails captured only for the moment the switcher is open, then released.
- **Why the app checks its own code signature**: a permission grant is keyed to
  the code identity, so the app can tell the difference between "you have not
  granted this yet" and "you granted it to a copy macOS no longer recognises" —
  two states that look identical in System Settings but need opposite remedies.

### Thumbnails

`ThumbnailProvider` uses ScreenCaptureKit (`SCScreenshotManager.captureImage`)
with a per-window `SCContentFilter`, the modern non-deprecated capture path.
Shareable content is fetched once per gesture; each window is then rendered
directly at preview size, so no full-resolution bitmap is ever allocated. This
is why the minimum target is macOS 14.

## Project structure

```
WindowSwitcher/
├── build.sh                 # Compile with swiftc + assemble a signed .app bundle
├── setup-signing.sh         # Stable signing identity: create / export / import / status
├── reinstall.sh             # Clean reinstall: drop old copies + their stale TCC entries
├── Info.plist               # Bundle metadata (LSUIElement agent, min OS, icon, usage strings)
├── README.md
├── Tools/
│   └── main.swift               # Renders AppIcon.icns at build time (no committed asset)
└── Sources/
    ├── main.swift               # NSApplication bootstrap (accessory app)
    ├── AppDelegate.swift        # Lifecycle, menu bar, permission gating, relaunch
    ├── AppIcon.swift            # Menu-bar glyph + app icon artwork (one source)
    ├── AppSettings.swift        # Persisted, rebindable shortcut
    ├── SettingsWindow.swift     # Settings UI
    ├── PermissionsManager.swift # Accessibility / Screen Recording checks + deep links
    ├── AppIdentity.swift        # Code identity + install location: why a grant sticks or not
    ├── PermissionSetup.swift    # Diagnoses blockers; installs to /Applications, resets TCC
    ├── OnboardingWindow.swift   # First-run setup, blocker repairs, Restart App
    ├── HotKeyManager.swift      # CGEvent tap: modifier+key, and modifier-release
    ├── WindowEnumerator.swift   # Discover + filter real windows
    ├── WindowInfo.swift         # Value type for one window (id, title, app, icon)
    ├── WindowOrderManager.swift # Fixed or recently-used ordering
    ├── WindowActivator.swift    # Focus one window by CGWindowID (AX API)
    ├── ThumbnailProvider.swift  # ScreenCaptureKit previews
    ├── SwitcherController.swift # Orchestration
    ├── SwitcherPanel.swift      # Non-activating overlay panel
    └── SwitcherView.swift       # SwiftUI grid of window cards
```

## License

MIT — see `LICENSE`.
