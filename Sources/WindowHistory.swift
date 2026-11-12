import CoreGraphics

// The decision logic behind window ordering, kept free of AppKit,
// Accessibility and the window server so it can be unit-tested
// (`./build.sh test`). `WindowOrderManager` collects the live inputs and feeds
// them in here. All times are seconds of system uptime.

/// The history of window ids, most recently used first.
///
/// Only two operations change the order: `promote` and `reconcile`. Every
/// promotion has one documented cause in `WindowOrderManager`:
///   * the window that is current when the switcher opens,
///   * a window committed through the switcher,
///   * an external app activation that is not stale.
struct WindowHistory: Equatable {

    private(set) var order: [CGWindowID]

    init(order: [CGWindowID] = []) {
        var seen = Set<CGWindowID>()
        self.order = order.filter { seen.insert($0).inserted }
    }

    /// Moves `id` to the front, inserting it if it is new. Promoting the
    /// window that is already first changes nothing, so a duplicate
    /// activation event can't reorder anything.
    mutating func promote(_ id: CGWindowID) {
        guard order.first != id else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// Forgets windows that no longer exist (closed, or the app quit).
    ///
    /// A window that still exists but isn't on screen right now keeps its
    /// place. That covers a window on another Space, a hidden app (⌘H) or a
    /// minimised window, so it comes back where it was instead of at the end.
    mutating func reconcile(existing: Set<CGWindowID>) {
        order.removeAll { !existing.contains($0) }
    }

    /// Returns `visible` in history order. Ids not in the history yet are
    /// appended in the order given (front-to-back z-order) and recorded at the
    /// end of the history, so they keep that slot from then on.
    mutating func arrange(visible: [CGWindowID]) -> [CGWindowID] {
        let visibleSet = Set(visible)
        var known = Set(order)
        var result = order.filter { visibleSet.contains($0) }
        for id in visible where known.insert(id).inserted {
            result.append(id)
            order.append(id)
        }
        return result
    }

    /// Everything that happens to the history when the switcher opens, in
    /// order. Returns the visible windows in display order.
    ///
    /// - `existing`: every window that still exists. Pass nil if it couldn't
    ///   be read, and nothing will be forgotten.
    /// - `current`: the result of `WindowFocus.current`.
    mutating func prepareOpen(
        visible: [CGWindowID],
        existing: Set<CGWindowID>?,
        current: CGWindowID?,
        recentlyUsed: Bool
    ) -> [CGWindowID] {
        if let existing { reconcile(existing: existing.union(visible)) }
        if recentlyUsed, let current { promote(current) }
        return arrange(visible: visible)
    }

    /// The window pre-selected when the switcher opens: the one next to the
    /// current window. With no current window in the list (nothing focused,
    /// or it is on another display in per-display mode), the selection starts
    /// at the end the gesture is heading towards.
    ///
    /// In recently-used mode the current window has already been promoted to
    /// index 0, so a forward tap always lands on index 1, the previous window.
    static func initialSelection(count: Int, anchor: Int?, reverse: Bool) -> Int {
        guard count > 0 else { return 0 }
        guard let anchor else { return reverse ? count - 1 : 0 }
        let delta = reverse ? -1 : 1
        return ((anchor + delta) % count + count) % count
    }
}

/// A switch the switcher itself just made, which macOS may not have finished
/// carrying out yet.
///
/// Until the matching app activation arrives (or `deadline` passes), this is
/// a more reliable answer to "what is current?" than anything the system
/// reports. The window-server z-order and the frontmost application both lag
/// a just-issued activation, which is what made a rapid double tap skip a
/// window.
struct PendingCommit: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let deadline: Double

    /// How long a commit stays authoritative. That is long enough for a slow
    /// app to finish activating, and short enough that a later external
    /// switch is never overridden for long.
    static let lifetime: Double = 1.0

    init(pid: pid_t, windowID: CGWindowID, now: Double) {
        self.pid = pid
        self.windowID = windowID
        self.deadline = now + Self.lifetime
    }

    func isLive(at now: Double) -> Bool { now <= deadline }
}

enum WindowFocus {

    /// The window to treat as current when the switcher opens.
    ///
    /// The precedence is:
    ///   1. a live commit we just issued,
    ///   2. the system's focused window (frontmost app, then Accessibility).
    ///
    /// Either answer counts only if that window is in the visible list.
    /// `systemFocused` is a closure so the Accessibility round trip only
    /// happens when it is needed.
    static func current(
        pending: PendingCommit?,
        now: Double,
        visible: Set<CGWindowID>,
        systemFocused: () -> CGWindowID?
    ) -> CGWindowID? {
        if let pending, pending.isLive(at: now), visible.contains(pending.windowID) {
            return pending.windowID
        }
        if let id = systemFocused(), visible.contains(id) {
            return id
        }
        return nil
    }

    enum Decision: Equatable {
        case promote(CGWindowID)
        case ignoreOwnApp
        /// A newer activation has already happened, so this event is out of date.
        case ignoreStale
        case ignoreNoFocusedWindow
    }

    struct Outcome: Equatable {
        let decision: Decision
        /// Whether the pending commit is resolved or expired, and should be dropped.
        let clearPending: Bool
    }

    /// What an `NSWorkspace.didActivateApplication` notification should do to
    /// the history.
    ///
    /// - `frontmostPID`: the frontmost app at the time the notification is
    ///   handled, not at the time it was posted.
    /// - `axFocused`: the notified app's focused window according to
    ///   Accessibility. It is a closure because it costs an IPC round trip and
    ///   is only consulted for a genuine external switch.
    static func onActivation(
        notifiedPID: pid_t,
        frontmostPID: pid_t?,
        ownPID: pid_t,
        pending: PendingCommit?,
        now: Double,
        axFocused: () -> CGWindowID?
    ) -> Outcome {
        let pendingForThisApp = pending.map { $0.pid == notifiedPID && $0.isLive(at: now) } ?? false
        let pendingExpired = pending.map { !$0.isLive(at: now) } ?? false

        // The switcher's own Settings or Setup window coming forward. It is
        // never in the list, so it must not count as a switch.
        if notifiedPID == ownPID {
            return Outcome(decision: .ignoreOwnApp, clearPending: pendingExpired)
        }
        // Delivered after a newer activation. Promoting it would put a window
        // that is no longer in front at the head of the history.
        if let frontmostPID, frontmostPID != notifiedPID {
            return Outcome(decision: .ignoreStale, clearPending: pendingExpired || pendingForThisApp)
        }
        // This is the activation we asked for. Accessibility may still report
        // the app's previous window as focused (it hasn't processed the raise
        // yet, or ignores it), so the window we committed takes precedence.
        if let pending, pendingForThisApp {
            return Outcome(decision: .promote(pending.windowID), clearPending: true)
        }
        // A real external switch (Dock, mouse click, another app's request).
        // Any pending commit is now superseded.
        if let focused = axFocused() {
            return Outcome(decision: .promote(focused), clearPending: pending != nil)
        }
        return Outcome(decision: .ignoreNoFocusedWindow, clearPending: pending != nil)
    }
}
