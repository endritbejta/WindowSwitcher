# Window Switcher

A lightweight macOS utility that replaces the app-only Command+Tab with a
**Windows-style Alt+Tab** that cycles through **individual windows**.

Hold **Command**, press **Tab** to step forward (**Shift+Tab** to step back),
release **Command** to focus the selected window (Option and Control are also
available in Settings). Each window — including multiple windows of the same
app — is its own entry, shown with a live thumbnail and the app icon.

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

## Build & run

Requires macOS 14+ and the Xcode command-line tools.

```bash
cd WindowSwitcher
./setup-signing.sh     # once per Mac — see below, this is what makes grants stick
./build.sh install     # build, install into /Applications, launch
```

`build.sh` compiles `Sources/*.swift` into `build/WindowSwitcher.app`, generates
the app icon, and signs the bundle. The app runs in the background (no Dock icon)
with a menu-bar item for status and Quit.

| Command | What it does |
|---|---|
| `./build.sh` | Build into `build/WindowSwitcher.app` |
| `./build.sh run` | Build, then launch from `build/` |
| `./build.sh install` | Build, install into `/Applications`, launch from there |
| `./build.sh doctor` | Report the code identity and anything that would break grants |

**Install into `/Applications`.** Running from `Downloads` or the Desktop invites
macOS to quarantine and *translocate* the app — run it from a randomised
throwaway path — and a permission granted to a throwaway path dies with it.

### Stable signing (run once per Mac)

```bash
./setup-signing.sh
```

macOS ties a permission grant to the app's **code identity**, so an app whose
identity changes loses its grants. An ad-hoc signature (`codesign --sign -`) is
pinned to the binary's own hash and therefore changes on *every single rebuild* —
which is why `build.sh` now **refuses** to produce an ad-hoc build rather than
handing you an app that silently forgets its permissions. `setup-signing.sh`
creates a self-signed certificate in a dedicated throwaway keychain, giving the
app a constant identity so a grant given once survives every future rebuild.

### Using it on a second Mac

The certificate is what the grant is pinned to, so both Macs must sign with the
**same** certificate — generating a fresh one on each machine produces two
identities and the second Mac never keeps its grant. Export it from the Mac that
already works and import it on the other:

```bash
# on the Mac that works
./setup-signing.sh export ~/Desktop/ws-identity.p12

# on the other Mac, after copying the file across
./setup-signing.sh import ~/Desktop/ws-identity.p12
./build.sh install
```

Then delete the `.p12`. It is a signing key: anything signed with it inherits
this app's Accessibility permission, which is why it is deliberately **not**
committed to this repository.

`./setup-signing.sh status` prints the identity and the requirement it produces,
so you can confirm both Macs match.

If you have a paid Apple Developer account, `build.sh` prefers a **Developer ID**
identity automatically when it finds one — that is stable across machines with no
certificate shuffling at all.

## Permissions

On first launch a setup window guides you through two required permissions and
polls until both are granted:

- **Accessibility** — read the switch shortcut (via a `CGEvent` tap) and
  raise/focus the chosen window (via the Accessibility API).
- **Screen Recording** — capture window thumbnails and read window titles.

Only **Accessibility** is required — the switcher starts the moment it's
granted. **Screen Recording** is optional: without it the switcher still works,
it just shows app icons instead of live thumbnails.

**A freshly-granted permission usually needs a relaunch to take effect** (macOS
caches the old state inside the running process — Screen Recording especially).
The setup window has a **Restart App** button for exactly this; use it after
flipping a toggle.

### "I granted it but the app doesn't recognise it"

macOS does not remember a grant by app name. It stores it against the app's
**designated requirement**, a code-signing predicate. When that predicate
changes, the grant you already gave belongs to what macOS considers a different
app — the toggle still reads as ON in System Settings while the app is never
trusted, and no amount of toggling fixes it. There are exactly three causes, and
the app detects all three on launch and offers the repair instead of asking you
to toggle something again:

| Cause | What you see | Fix |
|---|---|---|
| **App Translocation** — a downloaded app runs from a randomised throwaway path | Grant never survives a quit | **Move to Applications** button |
| **Changed code identity** — rebuilt ad-hoc, or signed with a different certificate | Toggle is on, app disagrees | **Reset Permissions & Restart** button |
| **Ad-hoc signature** — identity pinned to the binary hash | Grant lost on every rebuild | `./setup-signing.sh`, then rebuild |

The setup window's **Copy Details** button copies the bundle path, signing kind
and designated requirement — enough to tell which of the three is in play. The
same facts are logged at launch:

```bash
log show --last 5m --predicate 'subsystem == "com.example.windowswitcher"'
```

`./build.sh` reports the identity on every build and shouts if it changed since
the last one, because that change is precisely what invalidates a grant.

To clear stale entries by hand:

```bash
tccutil reset Accessibility com.example.windowswitcher
tccutil reset ScreenCapture com.example.windowswitcher
```

then relaunch and grant once more.

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
| Permissions & onboarding | Preflight/request + deep links to Settings | `PermissionsManager.swift`, `OnboardingWindow.swift` |
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

### Settings

Open **Settings…** from the menu-bar item (or ⌘,):

- **Modifier** — Command (default), Option, or Control.
- **Trigger key** — Tab or Backtick (`` ` ``).
- **Window order** — *Recently used* (default; last-used window first, so a quick
  tap toggles between your two most recent windows) or *Fixed* (tiles never move).

Changes persist (`UserDefaults`) and take effect on the next keystroke — the
hot-key handler reads the binding live, so nothing needs restarting.

Choosing **Command** makes the app take over the system's own Command+Tab app
switcher while it's running (the switcher swallows the event); the Settings
window notes this. Window-filtering thresholds live in `WindowEnumerator.swift`.

Config lives in `AppSettings.swift`; the UI is `SettingsWindow.swift`.

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
    ├── WindowOrderManager.swift # Fixed or recently-used ordering
    ├── WindowActivator.swift    # Focus one window by CGWindowID (AX API)
    ├── ThumbnailProvider.swift  # ScreenCaptureKit previews
    ├── SwitcherController.swift # Orchestration
    ├── SwitcherPanel.swift      # Non-activating overlay panel
    └── SwitcherView.swift       # SwiftUI grid of window cards
```

## License

MIT — see `LICENSE`.
