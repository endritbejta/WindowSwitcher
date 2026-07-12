# Window Switcher

A lightweight macOS utility that replaces the app-only Command+Tab with a
**Windows-style Alt+Tab** that cycles through **individual windows**.

Hold **Option**, press **Tab** to step forward (**Shift+Tab** to step back),
release **Option** to focus the selected window. Each window — including
multiple windows of the same app — is its own entry, shown with a live
thumbnail, the app icon, and the window title.

## Features

- **Per-window switching**, not per-app — three Chrome windows are three entries.
- **Two-window toggle** — a quick tap flips between your two most recent windows,
  just like Windows Alt+Tab (recently-used order by default; a *Fixed* mode that
  keeps tiles in place is available in Settings).
- **Hold-and-release gesture** — cycle while the modifier is down, commit on release.
- **Rebindable shortcut** (Option / Command / Control × Tab / Backtick) via a
  native Settings window.
- **Live thumbnails** via ScreenCaptureKit, with app icon + title, and a
  highlighted selection.
- **Native SwiftUI overlay** with system materials — automatic Light/Dark mode.
- **Low overhead** — nothing runs while idle; windows and previews are captured
  only while the switcher is open.
- **Background agent** — no Dock icon, just a menu-bar item.

## Build & run

Requires macOS 14+ and the Xcode command-line tools.

```bash
cd WindowSwitcher
./build.sh run
```

This compiles `Sources/*.swift` into `build/WindowSwitcher.app` and launches it.
The app runs in the background (no Dock icon) with a menu-bar item
(a stacked-rectangles glyph) for status and Quit.

### Recommended: stable signing (run once)

```bash
./setup-signing.sh
```

By default `build.sh` uses an **ad-hoc** signature, which changes on every build
— so macOS forgets your permission grants each rebuild. `setup-signing.sh`
creates a local, self-signed code-signing certificate (in a dedicated throwaway
keychain) that gives the app a **constant** code identity. After running it once,
`build.sh` signs with that identity automatically and your Accessibility /
Screen Recording grants **persist across rebuilds**. See
[Permissions](#permissions) for details.

## Permissions

On first launch a setup window guides you through two required permissions and
polls until both are granted:

- **Accessibility** — read the Option+Tab shortcut (via a `CGEvent` tap) and
  raise/focus the chosen window (via the Accessibility API).
- **Screen Recording** — capture window thumbnails and read window titles.

Only **Accessibility** is required — the switcher starts the moment it's
granted. **Screen Recording** is optional: without it the switcher still works,
it just shows app icons instead of live thumbnails.

**A freshly-granted permission usually needs a relaunch to take effect** (macOS
caches the old state inside the running process — Screen Recording especially).
The setup window has a **Restart App** button for exactly this; use it after
flipping a toggle.

### Making grants survive rebuilds

macOS ties a permission grant to the app's **code identity**. With the default
ad-hoc signature that identity changes every build, so grants are forgotten each
rebuild. Run `./setup-signing.sh` once (see above) to sign with a stable
self-signed identity — then a grant given once persists across every future
rebuild.

If you switch signing modes (ad-hoc ↔ stable) the identity changes one last
time, so clear any stale entries and re-grant once:

```bash
tccutil reset Accessibility com.example.windowswitcher
tccutil reset ScreenCapture com.example.windowswitcher
```

then relaunch and grant. A freshly-toggled permission usually needs a relaunch
to take effect — the setup window's **Restart App** button does exactly that.

## How it works

| Concern | Approach | File |
|---|---|---|
| Discover all real windows | `CGWindowListCopyWindowInfo`, filtered to layer‑0, visible, non‑system windows | `WindowEnumerator.swift` |
| Window ordering | Fixed (stable positions) or recently‑used; own list seeded from z‑order | `WindowOrderManager.swift` |
| Global Option+Tab, and detecting Option **release** | `CGEvent` tap on keyDown + flagsChanged | `HotKeyManager.swift` |
| Focus one specific window | Accessibility API + `_AXUIElementGetWindow` to match by CGWindowID | `WindowActivator.swift` |
| Live previews | On‑demand ScreenCaptureKit stills rendered at preview size, off the main thread | `ThumbnailProvider.swift` |
| Overlay UI | SwiftUI grid in a non‑activating `NSPanel`, system materials for Light/Dark | `SwitcherView.swift`, `SwitcherPanel.swift` |
| Orchestration | Wires key events → selection → activation | `SwitcherController.swift` |
| Permissions & onboarding | Preflight/request + deep links to Settings | `PermissionsManager.swift`, `OnboardingWindow.swift` |
| Rebindable shortcut | Persisted modifier + trigger key, read live by the tap | `AppSettings.swift`, `SettingsWindow.swift` |
| Lifecycle / menu bar | Accessory app, status item | `AppDelegate.swift`, `main.swift` |

### Design notes

- **Why an event tap** rather than a Carbon hot-key: only the raw event stream
  tells us when Option is *released*, which is how the Windows gesture commits.
- **Why a non-activating panel**: showing the overlay must not steal focus from
  the app you're holding Option over, or releasing Option couldn't end the
  gesture cleanly.
- **Why `_AXUIElementGetWindow`**: macOS has no public "focus this CGWindowID"
  call. This private-but-stable helper maps an Accessibility element to its
  CGWindowID so we can raise the exact window even when several share a title.
- **Low overhead**: nothing polls while idle. Windows are enumerated and
  thumbnails captured only for the moment the switcher is open, then released.

### Settings

Open **Settings…** from the menu-bar item (or ⌘,):

- **Modifier** — Option, Command, or Control.
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
├── setup-signing.sh         # One-time: create a stable self-signed identity
├── Info.plist               # Bundle metadata (LSUIElement agent, min OS, usage strings)
├── README.md
└── Sources/
    ├── main.swift               # NSApplication bootstrap (accessory app)
    ├── AppDelegate.swift        # Lifecycle, menu bar, permission gating, relaunch
    ├── AppSettings.swift        # Persisted, rebindable shortcut
    ├── SettingsWindow.swift     # Settings UI
    ├── PermissionsManager.swift # Accessibility / Screen Recording checks + deep links
    ├── OnboardingWindow.swift   # First-run setup + Restart App
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
