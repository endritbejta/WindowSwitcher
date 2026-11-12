import AppKit

/// Decides the order windows appear in the switcher.
///
/// There are two modes, chosen in Settings (`AppSettings.windowOrder`):
///
///   * **Recently used** (default): the window you are on heads the list and
///     the one you were on before it comes next, so a quick tap toggles
///     between them, as Windows Alt+Tab does.
///   * **Fixed**: each window keeps its slot. New windows are appended and
///     closed windows removed, but existing windows never move.
///
/// macOS keeps no per-window focus history, so the switcher builds its own.
/// All of the state and every rule that changes it live in
/// `WindowOrderState` (WindowHistory.swift), where the unit tests exercise
/// that exact code. This class only does the I/O: it reads the window
/// server, NSWorkspace and Accessibility, and feeds what it reads in:
///
///   1. **On open**, the window that is actually current is promoted. That is
///      the switcher's own just-issued commit if it is still settling,
///      otherwise the frontmost app's focused window. The list and the
///      pre-selection come from that one answer, so they can't disagree.
///      CG z-order is never used as "current", because it lags a fresh
///      activation.
///   2. **On commit**, the chosen window is promoted and recorded as pending,
///      so the app activation it causes promotes that window rather than
///      whatever Accessibility reports a moment too early.
///   3. **On external activation**, the app's focused window is promoted,
///      unless the notification predates a commit still settling or is about
///      this app's own windows.
///   4. **On focus moving inside the frontmost app**, reported by
///      `FocusObserver`, that window is promoted.
final class WindowOrderManager {

    private var state = WindowOrderState()

    /// The window treated as current at the last `orderedWindows()` call. The
    /// controller anchors the pre-selection on it. It is nil when nothing in
    /// the list has focus, for example the desktop or this app's own Settings
    /// window.
    private(set) var currentWindowID: CGWindowID?

    private var isRecentlyUsed: Bool { AppSettings.shared.windowOrder == .recentlyUsed }

    /// Monotonic time, the same clock `PendingCommit` deadlines use.
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Watches the frontmost app for focus moving between its own windows
    /// (⌘`, clicks, new windows). macOS sends no workspace notification for
    /// that.
    private lazy var focusObserver = FocusObserver { [weak self] pid, windowID in
        self?.focusedWindowDidChange(pid: pid, windowID: windowID)
    }

    private var isStarted = false

    /// Begins observing. `SwitcherController` calls this once the event tap
    /// is live, which also means Accessibility has been granted.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Seed from the current front-to-back z-order.
        state = WindowOrderState(seed: WindowEnumerator.currentWindows().map(\.id))

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        observeFocus(of: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        focusObserver.stopObserving()
        state.clearPending()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Points the focus observer at `pid`, or stops it when the frontmost app
    /// is unknown or is this app, whose windows are never listed.
    private func observeFocus(of pid: pid_t?) {
        if let pid, pid != getpid() {
            focusObserver.observe(pid: pid)
        } else {
            focusObserver.stopObserving()
        }
    }

    /// Returns the on-screen windows in the configured order, and sets
    /// `currentWindowID` for this gesture.
    func orderedWindows() -> [WindowInfo] {
        let visible = WindowEnumerator.currentWindows()
        let before = state.history.order
        let pendingAtOpen = state.pending

        let opened = state.open(
            visible: visible.map(\.id),
            // Only windows that are gone are forgotten. Windows on another
            // Space, hidden or minimised keep their place. If the full list
            // can't be read, nothing is forgotten, rather than risk wiping
            // the history.
            existing: WindowEnumerator.existingWindowIDs(),
            recentlyUsed: isRecentlyUsed,
            now: now
        ) {
            WindowFocus.systemFocused(
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                ownPID: getpid(),
                visible: visible.map { (id: $0.id, pid: $0.pid) },
                axFocused: WindowActivator.focusedWindowID(forPID:)
            )
        }
        currentWindowID = opened.current

        var byID: [CGWindowID: WindowInfo] = [:]
        for window in visible { byID[window.id] = window }
        let result = opened.ordered.compactMap { byID[$0] }

        logSnapshot(before: before, visible: visible, opened: opened, pendingAtOpen: pendingAtOpen)
        return result
    }

    /// Records a window the user chose in the switcher. Call it just before
    /// asking macOS to activate the window.
    func noteCommit(_ window: WindowInfo) {
        // Pending is recorded in both modes. In fixed mode it still anchors
        // the next open's pre-selection while the activation settles.
        let before = state.history.order
        state.commit(
            pid: window.pid,
            windowID: window.id,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            recentlyUsed: isRecentlyUsed,
            now: now
        )
        logChange("commit \(MRULog.describe(window.id)) expectsActivation=\(state.pending?.expectsActivation ?? false)", before: before)
    }

    @objc private func appDidActivate(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        let before = state.history.order

        var axFocused: CGWindowID?
        let outcome = state.activation(
            notifiedPID: pid, ownPID: getpid(), recentlyUsed: isRecentlyUsed, now: now
        ) {
            axFocused = WindowActivator.focusedWindowID(forPID: pid)
            return axFocused
        }
        logChange(
            "didActivate pid=\(pid)(\(app.localizedName ?? "?")) axFocused=\(MRULog.describe(axFocused))"
            + " decision=\(outcome.decision) clearPending=\(outcome.clearPending)",
            before: before
        )

        switch outcome.decision {
        case .ignoreStale:
            // It predates our own switch, so keep watching whichever app the
            // observer is on. Our activation retargets it when it arrives.
            break
        case .ignoreOwnApp:
            focusObserver.stopObserving()
        case .promote, .ignoreNoFocusedWindow:
            observeFocus(of: pid)
        }
    }

    /// The observed app moved keyboard focus to another of its windows.
    private func focusedWindowDidChange(pid: pid_t, windowID: CGWindowID) {
        let before = state.history.order
        let outcome = state.focusChanged(pid: pid, windowID: windowID, recentlyUsed: isRecentlyUsed, now: now)
        logChange(
            "focusChanged pid=\(pid) window=\(MRULog.describe(windowID))"
            + " decision=\(outcome.decision) clearPending=\(outcome.clearPending)",
            before: before
        )
    }

    // MARK: - Diagnostics (no-ops unless MRULog is enabled)

    private func logChange(_ event: @autoclosure () -> String, before: [CGWindowID]) {
        guard MRULog.isEnabled else { return }
        let after = state.history.order
        MRULog.info(event() + (after == before ? " order unchanged" : " order \(MRULog.describe(before)) → \(MRULog.describe(after))"))
    }

    private func logSnapshot(
        before: [CGWindowID],
        visible: [WindowInfo],
        opened: WindowOrderState.Opened,
        pendingAtOpen: PendingCommit?
    ) {
        guard MRULog.isEnabled else { return }
        MRULog.remember(visible)

        let zFront = visible.first?.id
        let focus = MRULog.actualFocus()
        let order = state.history.order
        let dropped = before.filter { !order.contains($0) }
        let source = opened.current == nil ? "none" : (opened.currentFromPending ? "pending" : "system")
        MRULog.info(
            "open mode=\(AppSettings.shared.windowOrder.rawValue)"
            + " current=\(MRULog.describe(opened.current)) source=\(source)"
            + " pending=\(pendingAtOpen.map { "\(MRULog.describe($0.windowID)) live=\($0.isLive(at: now))" } ?? "nil")"
            + " zFront=\(MRULog.describe(zFront))"
            + " systemFocused=\(MRULog.describe(focus?.windowID)) frontmostApp=\(focus.map { "\($0.pid)(\($0.app))" } ?? "nil")"
            + " order=\(MRULog.describe(order))"
            + (dropped.isEmpty ? "" : " dropped=\(MRULog.describe(dropped))")
        )

        // These two are informational now. Neither feeds the selection any
        // more, but they show how often the old anchor would have been wrong.
        if let focused = focus?.windowID, focused != zFront {
            MRULog.info("zorder-lag zFront=\(MRULog.describe(zFront)) systemFocused=\(MRULog.describe(focused))")
        }
        if opened.currentFromPending, let focused = focus?.windowID, focused != opened.current {
            MRULog.info("system still settling: using pending \(MRULog.describe(opened.current)), system reports \(MRULog.describe(focused))")
        }

        // The one ordering invariant. In recently-used mode the current
        // window must head the list, or the pre-selection is wrong.
        if isRecentlyUsed, let current = opened.current, order.first != current {
            MRULog.anomaly("head-not-current", "head=\(MRULog.describe(order.first)) current=\(MRULog.describe(current))")
        }
    }
}
