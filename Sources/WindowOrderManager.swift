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

        let previousOrder = order
        order = result.map(\.id)
        logSnapshot(previousOrder: previousOrder, current: current)
        return result
    }

    /// Promote a window to the front — only in recently-used mode. In fixed
    /// mode this is a no-op so the list keeps its positions. `source` only
    /// labels the diagnostic log line.
    func markUsed(_ id: CGWindowID, source: String) {
        guard AppSettings.shared.windowOrder == .recentlyUsed else { return }
        let before = order
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        MRULog.info("promote \(MRULog.describe(id)) source=\(source) before=\(MRULog.describe(before)) after=\(MRULog.describe(order))")
    }

    /// Diagnostics for one `orderedWindows()` call: what the switcher believes
    /// (stored history, CG z-order front) against what actually has focus.
    private func logSnapshot(previousOrder: [CGWindowID], current: [WindowInfo]) {
        guard MRULog.isEnabled else { return }
        MRULog.remember(current)

        let focus = MRULog.actualFocus()
        let pruned = previousOrder.filter { !order.contains($0) }
        MRULog.info(
            "open mode=\(AppSettings.shared.windowOrder.rawValue)"
            + " zFront=\(MRULog.describe(frontWindowID))"
            + " focused=\(MRULog.describe(focus?.windowID)) frontmostApp=\(focus.map { "\($0.pid)(\($0.app))" } ?? "nil")"
            + " order=\(MRULog.describe(order))"
            + (pruned.isEmpty ? "" : " pruned=\(MRULog.describe(pruned))")
        )

        if let focused = focus?.windowID, focused != frontWindowID {
            // The selection is anchored on zFront, so this is the lag that
            // makes a quick tap skip a window.
            MRULog.anomaly("zorder-lag", "zFront=\(MRULog.describe(frontWindowID)) focused=\(MRULog.describe(focused))")
        }
        if AppSettings.shared.windowOrder == .recentlyUsed,
           let focused = focus?.windowID, let head = order.first, head != focused {
            MRULog.anomaly("head-not-focused", "head=\(MRULog.describe(head)) focused=\(MRULog.describe(focused))")
        }
        if !pruned.isEmpty {
            // Windows that left the on-screen list (other Space, hidden,
            // minimised, closed) lose their history slot here.
            MRULog.info("pruned \(MRULog.describe(pruned)) from history")
        }
    }

    /// External app activation bumps that app's focused window — recently-used
    /// mode only. Uses Accessibility's focused-window attribute rather than
    /// CG window-list z-order, which can still reflect the *previous* order for
    /// a moment after activation and would otherwise promote the wrong window
    /// of a multi-window app.
    @objc private func appDidActivate(_ note: Notification) {
        guard AppSettings.shared.windowOrder == .recentlyUsed else { return }
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let focusedID = WindowActivator.focusedWindowID(forPID: app.processIdentifier)

        if MRULog.isEnabled {
            let pid = app.processIdentifier
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            MRULog.info(
                "didActivate pid=\(pid)(\(app.localizedName ?? "?")) frontmostNow=\(frontmost.map(String.init) ?? "nil")"
                + " axFocused=\(MRULog.describe(focusedID))"
            )
            if pid == getpid() {
                MRULog.anomaly("self-activation", "own app activated; promoting \(MRULog.describe(focusedID))")
            } else if let frontmost, frontmost != pid {
                // Delivered after a newer activation — promoting now puts a
                // window that is no longer front at the head of history.
                MRULog.anomaly("stale-notification", "notified pid=\(pid) but frontmost is pid=\(frontmost)")
            }
            if focusedID == nil {
                MRULog.info("didActivate pid=\(pid): no AX focused window, nothing promoted")
            }
        }

        if let id = focusedID {
            markUsed(id, source: "didActivate")
        }
    }
}
