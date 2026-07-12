# Window Switcher

A lightweight macOS utility that replaces the app-only Command+Tab with a
**Windows-style Alt+Tab** that cycles through **individual windows** in
most-recently-used order.

Hold **Option**, press **Tab** to step forward (**Shift+Tab** to step back),
release **Option** to focus the selected window. Each window — including
multiple windows of the same app — is its own entry, shown with a live
thumbnail, the app icon, and the window title.

## Features

- **Per-window switching**, not per-app — three Chrome windows are three entries.
- **MRU order**, like Windows Alt+Tab: the window you were just on comes first.
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

### If a permission still won't "stick"

The build uses an **ad-hoc signature**, so every `./build.sh` produces a new
code identity. A grant you gave to a *previous* build does not carry over, and
you may see a stale entry in the Accessibility list. Reliable procedure:

1. Build once, launch, grant Accessibility (and optionally Screen Recording).
2. Click **Restart App**.
3. Avoid rebuilding after granting. If you do rebuild, reset the old grants
   first:
   ```bash
   tccutil reset Accessibility com.example.windowswitcher
   tccutil reset ScreenCapture   com.example.windowswitcher
   ```
   then relaunch and grant again.

For a grant that survives rebuilds, sign with a stable identity (a self-signed
or Developer ID certificate) instead of the ad-hoc `-` in `build.sh`.

## How it works

| Concern | Approach | File |
|---|---|---|
| Discover all real windows | `CGWindowListCopyWindowInfo`, filtered to layer‑0, visible, non‑system windows | `WindowEnumerator.swift` |
| MRU ordering | Own list seeded from z‑order, bumped on switch and on app activation | `MRUWindowManager.swift` |
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

Open **Settings…** from the menu-bar item (or ⌘,) to rebind the shortcut:

- **Modifier** — Option, Command, or Control.
- **Trigger key** — Tab or Backtick (`` ` ``).

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
    ├── MRUWindowManager.swift   # Most-recently-used ordering
    ├── WindowActivator.swift    # Focus one window by CGWindowID (AX API)
    ├── ThumbnailProvider.swift  # ScreenCaptureKit previews
    ├── SwitcherController.swift # Orchestration
    ├── SwitcherPanel.swift      # Non-activating overlay panel
    └── SwitcherView.swift       # SwiftUI grid of window cards
```

## License

MIT — see `LICENSE`.
