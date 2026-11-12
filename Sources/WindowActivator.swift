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

    /// Upper bound, in seconds, on one focused-window query. A responsive app
    /// answers in well under a millisecond.
    private static let focusQueryTimeout: Float = 0.25

    /// The CGWindowID of `pid`'s currently-focused window, via the
    /// Accessibility API's `kAXFocusedWindowAttribute`.
    ///
    /// This is used instead of reading window z-order right after an
    /// activation notification: `CGWindowListCopyWindowInfo` can lag a beat
    /// behind the window server actually reordering, so for an app with
    /// several windows "the frontmost one in the CG list" was occasionally the
    /// wrong window — the MRU list would then promote a window the user hadn't
    /// actually touched.
    ///
    /// Asking the app directly avoids that lag, but it isn't race-free. Just
    /// after a raise the app can still report its previous window. That is
    /// why `WindowOrderManager` trusts its own pending commit over this answer
    /// while a switch settles.
    static func focusedWindowID(forPID pid: pid_t) -> CGWindowID? {
        // Without the id helper the answer can't be used, so skip the IPC.
        guard getWindowID != nil else { return nil }
        _ = configureMessagingTimeout
        let appElement = AXUIElementCreateApplication(pid)
        // This runs on every switcher open and every app activation, on the
        // main thread that also services the key-event tap. Without a cap, a
        // hung app would block it for AX's default timeout of several seconds.
        AXUIElementSetMessagingTimeout(appElement, focusQueryTimeout)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return windowID(of: value as! AXUIElement)
    }

    /// The CGWindowID behind an Accessibility window element, or nil if the
    /// private helper is unavailable or the element isn't a window.
    static func windowID(of axWindow: AXUIElement) -> CGWindowID? {
        guard let getWindowID else { return nil }
        var wid: CGWindowID = 0
        guard getWindowID(axWindow, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// The CGWindowIDs of every window `pid` reports through Accessibility
    /// (`kAXWindowsAttribute`), or nil if the app can't be asked: Accessibility
    /// isn't granted, the id helper is missing, or the call fails or times out.
    ///
    /// `WindowFilter` uses this to recognise windows the window server lists
    /// but the app doesn't own as windows, such as the toolbar strip of a
    /// full-screen app.
    static func accessibleWindowIDs(forPID pid: pid_t) -> Set<CGWindowID>? {
        guard getWindowID != nil else { return nil }
        _ = configureMessagingTimeout
        let appElement = AXUIElementCreateApplication(pid)
        // Runs while the switcher opens, on the main thread; see `focusQueryTimeout`.
        AXUIElementSetMessagingTimeout(appElement, focusQueryTimeout)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return nil }
        return Set(windows.compactMap(windowID(of:)))
    }

    /// Upper bound, in seconds, on any single Accessibility call this app
    /// makes. AX's default is several seconds per call. All of these calls
    /// run on the main thread, which also services the key-event tap, so one
    /// hung app could otherwise freeze the keyboard. Raising a window takes
    /// several calls, so the budget is per call, and the sequence stops at the
    /// first one that times out.
    private static let messagingTimeout: Float = 0.5

    /// Sets the process-wide default once. Setting it on the system-wide
    /// element applies it to every element that has no timeout of its own.
    private static let configureMessagingTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }()

    /// Applies the process-wide Accessibility timeout. `SwitcherController`
    /// calls this before anything else talks to another app, including
    /// `FocusObserver`'s registration at startup. Calling it again does
    /// nothing. The calls inside this type also apply it, as a backstop.
    static func installMessagingTimeout() {
        _ = configureMessagingTimeout
    }

    /// Focus the given window. Safe to call from the main thread.
    static func activate(_ window: WindowInfo) {
        _ = configureMessagingTimeout
        let appElement = AXUIElementCreateApplication(window.pid)

        if let axWindow = accessibilityWindow(for: window, in: appElement) {
            // These four calls go in order, and the sequence stops at the
            // first that can't complete. An app that didn't answer the first
            // won't answer the rest, and each attempt would cost the full
            // timeout.
            let steps: [() -> AXError] = [
                // Un-minimise. Only on-screen windows are listed today, so this
                // is a no-op unless a window is minimised mid-gesture. It is
                // the step that would bring a window back if minimised windows
                // were ever listed.
                { AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse) },
                // Make it the app's main/active window and raise it above siblings.
                { AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue) },
                // And give it keyboard focus specifically. Main and focused are
                // separate in AppKit, and the gap between them shows up most when
                // switching between two windows of the *same* app on different
                // displays: raising alone can leave the app still typing into the
                // window on the screen you just left.
                { AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue) },
                { AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString) },
            ]
            for step in steps {
                if step() == .cannotComplete {
                    MRULog.anomaly("ax-timeout", "raising window \(window.id) of pid \(window.pid); remaining AX steps skipped")
                    break
                }
            }
        }

        // Finally bring the owning application forward so the raised window
        // actually receives keyboard focus.
        // The deployment target is macOS 14, so the old
        // `.activateIgnoringOtherApps` fallback could never run.
        NSRunningApplication(processIdentifier: window.pid)?.activate()
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

        // Fallback: match by title and top-left corner.
        for axWindow in axWindows where axWindowMatches(axWindow, window) {
            return axWindow
        }
        // No match. With the id helper available that is a definite answer:
        // the window is gone, or isn't one the app exposes. Raising some other
        // window of the app would leave the user on a window they never chose.
        // Without the helper, keep the old best effort of raising the first.
        return getWindowID == nil ? axWindows.first : nil
    }

    private static func axWindowMatches(_ axWindow: AXUIElement, _ window: WindowInfo) -> Bool {
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
        let axTitle = (titleValue as? String) ?? ""
        if !window.title.isEmpty && axTitle == window.title {
            return true
        }

        var posValue: CFTypeRef?
        // The type is checked before the cast. An app that returns something
        // other than an AXValue here would otherwise crash the switcher.
        guard
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posValue) == .success,
            let posValue,
            CFGetTypeID(posValue) == AXValueGetTypeID()
        else {
            return false
        }
        var point = CGPoint.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point) else { return false }
        return abs(point.x - window.frame.origin.x) < 2 && abs(point.y - window.frame.origin.y) < 2
    }
}
