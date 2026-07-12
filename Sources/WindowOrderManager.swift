import AppKit

/// Decides the order windows appear in the switcher.
///
/// Two modes, chosen in Settings (`AppSettings.windowOrder`):
///
///   * **Fixed** (default) — each window keeps its slot. New windows are
///     appended, closed windows removed, but existing windows never move. This
///     keeps the tiles stable so their positions are predictable between
///     switches.
///   * **Recently used** — the window you just switched to jumps to the front,
///     matching the Windows Alt+Tab feel.
///
/// macOS gives us no global per-window focus history, so in recently-used mode
/// we build our own from two signals: windows we activate through the switcher,
/// and external app activations.
final class WindowOrderManager {

    /// Window ids in display order. In fixed mode this only grows/shrinks; in
    /// recently-used mode entries are also moved to the front on use.
    private var order: [CGWindowID] = []

    /// The frontmost (currently focused) window at the last `orderedWindows()`
    /// call, taken from the live z-order. Used to seed the initial selection.
    private(set) var frontWindowID: CGWindowID?

    init() {
        // Seed from the current front-to-back z-order.
        order = WindowEnumerator.currentWindows().map(\.id)

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

    /// Returns the currently-open windows in the configured order. Newly
    /// appeared windows are appended; ids that no longer exist are pruned.
    func orderedWindows() -> [WindowInfo] {
        let current = WindowEnumerator.currentWindows()
        frontWindowID = current.first?.id   // z-order front == focused window

        var byID: [CGWindowID: WindowInfo] = [:]
        for window in current { byID[window.id] = window }

        var result: [WindowInfo] = []
        var seen = Set<CGWindowID>()

        // Known windows, in their stored order.
        for id in order {
            if let window = byID[id] {
                result.append(window)
                seen.insert(id)
            }
        }
        // Windows we haven't seen before, appended in z-order.
        for window in current where !seen.contains(window.id) {
            result.append(window)
        }

        order = result.map(\.id)
        return result
    }

    /// Promote a window to the front — only in recently-used mode. In fixed
    /// mode this is a no-op so the list keeps its positions.
    func markUsed(_ id: CGWindowID) {
        guard AppSettings.shared.windowOrder == .recentlyUsed else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// External app activation bumps that app's frontmost window — recently-used
    /// mode only.
    @objc private func appDidActivate(_ note: Notification) {
        guard AppSettings.shared.windowOrder == .recentlyUsed else { return }
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        if let front = WindowEnumerator.currentWindows().first(where: { $0.pid == app.processIdentifier }) {
            markUsed(front.id)
        }
    }
}
