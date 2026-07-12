import AppKit

/// Maintains a most-recently-used ordering of windows, so the switcher lists
/// them the way Windows Alt+Tab does: the window you were just on is first, the
/// one before that is second, and so on.
///
/// macOS gives us no global per-window focus history, so we build our own from
/// two signals:
///   * The window we activate through the switcher jumps to the front.
///   * When any app becomes frontmost (user clicked another window, Cmd+Tabbed,
///     etc.) we bump that app's frontmost window to the front.
///
/// The result is a good approximation of a true MRU — exact for switches made
/// through this app, and close enough for external focus changes.
final class MRUWindowManager {

    /// Window ids in MRU order, most-recent first.
    private var order: [CGWindowID] = []

    init() {
        // Seed from the current front-to-back z-order.
        order = WindowEnumerator.currentWindows().map(\.id)

        // Track external app activations to keep the ordering fresh.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Returns the currently-open windows sorted by our MRU ordering. Any newly
    /// appeared windows (not yet in `order`) are appended after the known ones.
    func orderedWindows() -> [WindowInfo] {
        let current = WindowEnumerator.currentWindows()
        var byID: [CGWindowID: WindowInfo] = [:]
        for window in current { byID[window.id] = window }

        var result: [WindowInfo] = []
        var seen = Set<CGWindowID>()

        // Known windows, in MRU order.
        for id in order {
            if let window = byID[id] {
                result.append(window)
                seen.insert(id)
            }
        }
        // Windows we haven't seen before, in z-order.
        for window in current where !seen.contains(window.id) {
            result.append(window)
        }

        // Prune ids that no longer exist so `order` doesn't grow unbounded.
        order = result.map(\.id)
        return result
    }

    /// Promote a window to the front of the MRU list. Called right after we
    /// activate a window through the switcher.
    func markUsed(_ id: CGWindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// When another app is activated externally, move its frontmost window to
    /// the top of our ordering so it appears first next time.
    @objc private func appDidActivate(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier

        // The frontmost window of that app is whichever of its windows appears
        // earliest in the current z-order.
        if let frontWindow = WindowEnumerator.currentWindows().first(where: { $0.pid == pid }) {
            markUsed(frontWindow.id)
        }
    }
}
