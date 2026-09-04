import AppKit
import CoreGraphics

/// A single, individually-switchable window belonging to some application.
///
/// This is the unit the switcher cycles through — one entry per real window,
/// so an app with three windows contributes three `WindowInfo` values (this is
/// the core difference from macOS's built-in app-only Command+Tab switcher).
struct WindowInfo: Identifiable, Equatable {
    /// The CoreGraphics window id. Stable for the lifetime of the window and
    /// used both for capturing a thumbnail and for matching against the
    /// Accessibility window when we activate it.
    let id: CGWindowID

    /// Owning process id — used to talk to the app via the Accessibility API
    /// and to activate it with `NSRunningApplication`.
    let pid: pid_t

    /// Human-readable application name (e.g. "Google Chrome").
    let appName: String

    /// The window's own title (e.g. a specific browser tab or document).
    /// Requires Screen Recording permission to be populated by CoreGraphics;
    /// we fall back to the app name when it is empty.
    let title: String

    /// On-screen frame in global (top-left origin) coordinates.
    let frame: CGRect

    /// The owning app's icon. Always available, so it doubles as the
    /// placeholder shown until the live thumbnail finishes rendering.
    let appIcon: NSImage?

    /// The display this window is (mostly) on. Nil only if the window sits
    /// entirely outside every attached screen, which happens for a moment
    /// while a display is being connected or rearranged.
    let display: DisplayRef?

    /// What we actually show as the label: prefer the window title, fall back
    /// to the app name so an entry is never blank.
    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    /// Points-to-pixels factor of the display this window is on. Previews are
    /// captured at this density so a window on a Retina screen doesn't come
    /// back soft just because a 1x monitor is plugged in next to it.
    var displayScale: CGFloat {
        // Capped at 2: beyond that the extra pixels are invisible in a tile
        // this small and only cost memory.
        min(display?.scale ?? 2, 2)
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
}
