import AppKit
import ApplicationServices

/// Brings a specific window to the front and gives it keyboard focus.
///
/// This is the trickiest native piece. macOS has no public "focus this exact
/// window by CGWindowID" call, so we:
///   1. Ask the owning app, via the Accessibility API, for all its windows.
///   2. Match the right one by its CGWindowID (using a private-but-stable
///      helper, `_AXUIElementGetWindow`).
///   3. Raise that window and mark it main, then activate the app.
enum WindowActivator {

    /// Function type of the private CoreGraphics helper that maps an
    /// Accessibility element to its CGWindowID. AltTab and many other switchers
    /// rely on it; it has been stable across macOS releases. We resolve it at
    /// runtime with `dlsym` so there is no link-time dependency on a private
    /// symbol.
    private typealias GetWindowFn = @convention(c)
        (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindowID: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    /// The CGWindowID of `pid`'s currently-focused window, via the
    /// Accessibility API's `kAXFocusedWindowAttribute`.
    ///
    /// This is used instead of reading window z-order right after an
    /// activation notification: `CGWindowListCopyWindowInfo` can lag a beat
    /// behind the window server actually reordering, so for an app with
    /// several windows "the frontmost one in the CG list" was occasionally the
    /// wrong window — the MRU list would then promote a window the user hadn't
    /// actually touched. Asking the app directly is race-free.
    static func focusedWindowID(forPID pid: pid_t) -> CGWindowID? {
        guard let getWindowID else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let value
        else { return nil }
        let axWindow = value as! AXUIElement

        var wid: CGWindowID = 0
        guard getWindowID(axWindow, &wid) == .success else { return nil }
        return wid
    }

    /// Focus the given window. Safe to call from the main thread.
    static func activate(_ window: WindowInfo) {
        let appElement = AXUIElementCreateApplication(window.pid)

        if let axWindow = accessibilityWindow(for: window, in: appElement) {
            // Un-minimise defensively in case the window was collapsed.
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            // Make it the app's main/active window and raise it above siblings.
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }

        // Finally bring the owning application forward so the raised window
        // actually receives keyboard focus.
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    /// Finds the Accessibility element for `window` among the app's windows,
    /// matching primarily by CGWindowID and falling back to title + position.
    private static func accessibilityWindow(
        for window: WindowInfo,
        in appElement: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
            let axWindows = value as? [AXUIElement]
        else {
            return nil
        }

        // Primary match: exact CGWindowID equality. This is unambiguous even
        // when an app has several identically-titled windows.
        if let getWindowID {
            for axWindow in axWindows {
                var wid: CGWindowID = 0
                if getWindowID(axWindow, &wid) == .success, wid == window.id {
                    return axWindow
                }
            }
        }

        // Fallback: match by title and top-left corner. Used only if the
        // private helper is ever unavailable.
        for axWindow in axWindows where axWindowMatches(axWindow, window) {
            return axWindow
        }
        return axWindows.first
    }

    private static func axWindowMatches(_ axWindow: AXUIElement, _ window: WindowInfo) -> Bool {
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
        let axTitle = (titleValue as? String) ?? ""
        if !window.title.isEmpty && axTitle == window.title {
            return true
        }

        var posValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posValue) == .success else {
            return false
        }
        var point = CGPoint.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        return abs(point.x - window.frame.origin.x) < 2 && abs(point.y - window.frame.origin.y) < 2
    }
}
