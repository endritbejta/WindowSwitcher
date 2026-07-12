import AppKit
import CoreGraphics

/// Discovers every normal, user-facing window across all running applications
/// using the CoreGraphics window-list API.
///
/// The heavy lifting is filtering: the raw window list contains menu bars, the
/// Dock, wallpaper, shadows, tooltips, status items and countless invisible
/// utility windows. We keep only the things a person would recognise as "a
/// window" and would expect Alt+Tab to land on.
enum WindowEnumerator {

    /// Applications whose windows we never want to surface. These own only
    /// system chrome (menu bar extras, notifications, the desktop) — never a
    /// real document window.
    private static let excludedOwners: Set<String> = [
        "Window Server",
        "WindowManager",       // Stage Manager / window tiling helper
        "Dock",
        "Control Center",
        "Notification Center",
        "Spotlight",
        "SystemUIServer",
        "Wallpaper",
        "Screenshot",
    ]

    /// Windows smaller than this in either dimension are treated as utility
    /// widgets (palettes, HUDs, tiny helper panels) and skipped.
    private static let minimumSize: CGFloat = 48

    /// Returns the current on-screen windows, front-to-back. CoreGraphics
    /// already returns them in front-to-back z-order, which is a decent proxy
    /// for recency the very first time we run, before our own MRU takes over.
    static func currentWindows() -> [WindowInfo] {
        // `.optionOnScreenOnly` excludes minimised/hidden windows; a Windows
        // Alt+Tab only shows windows you can actually switch to.
        // `.excludeDesktopElements` drops the wallpaper and desktop icons.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // Cache running apps by pid so we can fetch icons cheaply.
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            appsByPID[app.processIdentifier] = app
        }

        var result: [WindowInfo] = []
        for dict in raw {
            guard let info = makeWindowInfo(from: dict, appsByPID: appsByPID) else { continue }
            result.append(info)
        }
        return result
    }

    /// Converts one CoreGraphics window dictionary into a `WindowInfo`, or
    /// returns nil if it fails any of the "is this a real window" checks.
    private static func makeWindowInfo(
        from dict: [String: Any],
        appsByPID: [pid_t: NSRunningApplication]
    ) -> WindowInfo? {
        // Layer 0 is the normal application-window layer. Menus, the Dock, the
        // status bar, tooltips etc. all live on non-zero layers.
        guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0 else {
            return nil
        }

        // Fully transparent windows are invisible helpers.
        if let alpha = dict[kCGWindowAlpha as String] as? Double, alpha <= 0.01 {
            return nil
        }

        guard
            let windowNumber = dict[kCGWindowNumber as String] as? CGWindowID,
            let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
            let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else {
            return nil
        }

        // Skip tiny palettes/HUDs that aren't meaningful switch targets.
        if bounds.width < minimumSize || bounds.height < minimumSize {
            return nil
        }

        let ownerName = dict[kCGWindowOwnerName as String] as? String ?? ""
        if excludedOwners.contains(ownerName) {
            return nil
        }

        // Only surface windows from ordinary, activatable apps. This drops
        // background agents (activationPolicy `.prohibited`) that can still own
        // stray on-screen windows.
        let runningApp = appsByPID[pid]
        if let policy = runningApp?.activationPolicy, policy == .prohibited {
            return nil
        }

        let title = dict[kCGWindowName as String] as? String ?? ""

        return WindowInfo(
            id: windowNumber,
            pid: pid,
            appName: runningApp?.localizedName ?? ownerName,
            title: title,
            frame: bounds,
            appIcon: runningApp?.icon
        )
    }
}
