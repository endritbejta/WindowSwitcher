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
    /// Whether macOS will post a `didActivateApplication` for this commit.
    /// It will unless the target app was already the active one, for example
    /// when switching between two windows of the same app. Only a commit
    /// that expects an activation can make another app's activation stale.
    let expectsActivation: Bool

    /// How long a commit stays authoritative. That is long enough for a slow
    /// app to finish activating, and short enough that a later external
    /// switch is never overridden for long.
    static let lifetime: Double = 1.0

    init(pid: pid_t, windowID: CGWindowID, now: Double, expectsActivation: Bool = true) {
        self.pid = pid
        self.windowID = windowID
        self.deadline = now + Self.lifetime
        self.expectsActivation = expectsActivation
    }

    func isLive(at now: Double) -> Bool { now <= deadline }
}

/// Everything the switcher remembers about window order, and every
/// transition that changes it. `WindowOrderManager` gathers the live inputs
/// from macOS and calls these; the unit tests call exactly the same methods
/// with scripted inputs. No AppKit, no Accessibility, no window server.
struct WindowOrderState {

    private(set) var history: WindowHistory
    private(set) var pending: PendingCommit?

    init(seed: [CGWindowID] = []) {
        history = WindowHistory()
        _ = history.arrange(visible: seed)
    }

    struct Opened: Equatable {
        /// The visible windows in display order.
        let ordered: [CGWindowID]
        /// The window the pre-selection is anchored on.
        let current: CGWindowID?
        /// True when `current` came from the switcher's own settling commit
        /// rather than from asking the system.
        let currentFromPending: Bool
    }

    /// The switcher is opening. Resolves the current window, then updates and
    /// returns the order.
    mutating func open(
        visible: [CGWindowID],
        existing: Set<CGWindowID>?,
        recentlyUsed: Bool,
        now: Double,
        systemFocused: () -> CGWindowID?
    ) -> Opened {
        var askedSystem = false
        let current = WindowFocus.current(pending: pending, now: now, visible: Set(visible)) {
            askedSystem = true
            return systemFocused()
        }
        let ordered = history.prepareOpen(
            visible: visible, existing: existing, current: current, recentlyUsed: recentlyUsed
        )
        return Opened(ordered: ordered, current: current, currentFromPending: current != nil && !askedSystem)
    }

    /// The user chose `windowID` in the switcher, and macOS is about to be
    /// asked to activate it.
    ///
    /// - `frontmostPID`: the frontmost app as macOS reports it right now. It
    ///   is used only to tell whether an activation will follow, and an
    ///   earlier commit that is still settling takes precedence over it,
    ///   because during rapid taps the reported frontmost app lags.
    mutating func commit(pid: pid_t, windowID: CGWindowID, frontmostPID: pid_t?, recentlyUsed: Bool, now: Double) {
        let settling = pending.flatMap { $0.isLive(at: now) ? $0 : nil }
        let activeBefore = settling?.pid ?? frontmostPID
        pending = PendingCommit(pid: pid, windowID: windowID, now: now,
                                expectsActivation: activeBefore != pid)
        if recentlyUsed { history.promote(windowID) }
    }

    /// An `NSWorkspace.didActivateApplication` notification for `notifiedPID`.
    @discardableResult
    mutating func activation(
        notifiedPID: pid_t,
        ownPID: pid_t,
        recentlyUsed: Bool,
        now: Double,
        axFocused: () -> CGWindowID?
    ) -> WindowFocus.Outcome {
        let outcome = WindowFocus.onActivation(
            notifiedPID: notifiedPID, ownPID: ownPID, pending: pending, now: now, axFocused: axFocused
        )
        apply(outcome, recentlyUsed: recentlyUsed)
        return outcome
    }

    /// The observed app moved keyboard focus to `windowID`, one of its own
    /// windows.
    @discardableResult
    mutating func focusChanged(pid: pid_t, windowID: CGWindowID, recentlyUsed: Bool, now: Double) -> WindowFocus.Outcome {
        let outcome = WindowFocus.onFocusedWindowChanged(pid: pid, windowID: windowID, pending: pending, now: now)
        apply(outcome, recentlyUsed: recentlyUsed)
        return outcome
    }

    /// Observation stopped. Forget any commit still settling.
    mutating func clearPending() { pending = nil }

    private mutating func apply(_ outcome: WindowFocus.Outcome, recentlyUsed: Bool) {
        if outcome.clearPending { pending = nil }
        if recentlyUsed, case .promote(let id) = outcome.decision { history.promote(id) }
    }
}

enum WindowFocus {

    /// The window to treat as current when the switcher opens.
    ///
    /// The precedence is:
    ///   1. a live commit we just issued,
    ///   2. the system's focused window (see `systemFocused`).
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

    /// The system's answer to "which listed window has focus?"
    ///
    /// It is the frontmost app's Accessibility focused window if that window
    /// is listed. Otherwise (a palette or sheet is focused, or the app doesn't
    /// support Accessibility) it is that app's front-most listed window. It is
    /// nil when this app is frontmost, or the frontmost app lists nothing.
    ///
    /// - `visible`: front-to-back z-order.
    static func systemFocused(
        frontmostPID: pid_t?,
        ownPID: pid_t,
        visible: [(id: CGWindowID, pid: pid_t)],
        axFocused: (pid_t) -> CGWindowID?
    ) -> CGWindowID? {
        guard let pid = frontmostPID, pid != ownPID else { return nil }
        if let id = axFocused(pid), visible.contains(where: { $0.id == id }) {
            return id
        }
        return visible.first(where: { $0.pid == pid })?.id
    }

    enum Decision: Equatable {
        case promote(CGWindowID)
        case ignoreOwnApp
        /// It predates a switch the switcher has just made.
        case ignoreStale
        case ignoreNoFocusedWindow
    }

    struct Outcome: Equatable {
        let decision: Decision
        /// Whether the pending commit is resolved or superseded, and should be dropped.
        let clearPending: Bool
    }

    /// What an `NSWorkspace.didActivateApplication` notification should do to
    /// the history.
    ///
    /// Staleness is judged against the switcher's own pending commit, never
    /// against `NSWorkspace.frontmostApplication`, whose update timing
    /// relative to this notification isn't documented. macOS delivers
    /// activation notifications in the order the activations happened. So
    /// while a commit that expects its own activation is settling, any other
    /// app's activation was caused before it, and is out of date.
    ///
    /// - `axFocused`: the notified app's focused window according to
    ///   Accessibility. It is a closure because it costs an IPC round trip and
    ///   is only consulted for a genuine external switch.
    static func onActivation(
        notifiedPID: pid_t,
        ownPID: pid_t,
        pending: PendingCommit?,
        now: Double,
        axFocused: () -> CGWindowID?
    ) -> Outcome {
        let settling = pending.flatMap { $0.isLive(at: now) ? $0 : nil }

        // The switcher's own Settings or Setup window coming forward. It is
        // never in the list, so it must not count as a switch.
        if notifiedPID == ownPID {
            return Outcome(decision: .ignoreOwnApp, clearPending: pending != nil && settling == nil)
        }
        if let settling {
            // This is the activation we asked for. Accessibility may still
            // report the app's previous window as focused (it hasn't
            // processed the raise yet, or ignores it), so the window we
            // committed takes precedence.
            if settling.pid == notifiedPID {
                return Outcome(decision: .promote(settling.windowID), clearPending: true)
            }
            // Our own activation hasn't arrived yet, so this one came before it.
            if settling.expectsActivation {
                return Outcome(decision: .ignoreStale, clearPending: false)
            }
            // The commit stayed inside the already-active app, so no
            // activation of ours is coming. This is a real switch away from it.
        }
        // A real external switch (Dock, mouse click, another app's request).
        // Any pending commit is now superseded.
        if let focused = axFocused() {
            return Outcome(decision: .promote(focused), clearPending: pending != nil)
        }
        return Outcome(decision: .ignoreNoFocusedWindow, clearPending: pending != nil)
    }

    /// What an Accessibility focused-window-changed event from the observed
    /// app should do to the history. These events cover focus moving within
    /// one app, for example ⌘`, a click on a sibling window, or a new window.
    ///
    /// `FocusObserver` only reports events from the app it currently
    /// watches, and it is retargeted on every activation, so no frontmost
    /// check is needed here.
    static func onFocusedWindowChanged(
        pid: pid_t,
        windowID: CGWindowID,
        pending: PendingCommit?,
        now: Double
    ) -> Outcome {
        if let pending, pending.isLive(at: now) {
            // While a switch we asked for is settling, the only event that
            // counts is the committed window gaining focus. That covers two
            // cases:
            //   * the target app can report its previous window before it
            //     processes the raise;
            //   * the app being left can emit a last event before the
            //     observer moves on.
            if pending.pid == pid, windowID == pending.windowID {
                return Outcome(decision: .promote(windowID), clearPending: true)
            }
            return Outcome(decision: .ignoreStale, clearPending: false)
        }
        return Outcome(decision: .promote(windowID), clearPending: pending != nil)
    }
}
