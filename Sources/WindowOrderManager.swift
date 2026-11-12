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
/// The rules live in `WindowHistory.swift`, where they are unit-tested; this
/// class only gathers the live inputs for them:
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
///      unless the notification is stale or about this app's own windows.
final class WindowOrderManager {

    private var history = WindowHistory()
    private var pending: PendingCommit?

    /// The window treated as current at the last `orderedWindows()` call. The
    /// controller anchors the pre-selection on it. It is nil when nothing in
    /// the list has focus, for example the desktop or this app's own Settings
    /// window.
    private(set) var currentWindowID: CGWindowID?

    private var isRecentlyUsed: Bool { AppSettings.shared.windowOrder == .recentlyUsed }

    /// Monotonic time, the same clock `PendingCommit` deadlines use.
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    init() {
        // Seed from the current front-to-back z-order.
        _ = history.arrange(visible: WindowEnumerator.currentWindows().map(\.id))

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

    /// Returns the on-screen windows in the configured order, and sets
    /// `currentWindowID` for this gesture.
    func orderedWindows() -> [WindowInfo] {
        let visible = WindowEnumerator.currentWindows()
        let visibleIDs = Set(visible.map(\.id))
        let before = history.order

        let pendingAtOpen = pending
        var queriedSystem = false
        let current = WindowFocus.current(pending: pending, now: now, visible: visibleIDs) {
            queriedSystem = true
            return Self.systemFocusedWindow(in: visible)
        }
        currentWindowID = current

        // Only windows that are gone are forgotten. Windows on another Space,
        // hidden or minimised keep their place. If the full list can't be
        // read, nothing is forgotten, rather than risk wiping the history.
        let orderedIDs = history.prepareOpen(
            visible: visible.map(\.id),
            existing: WindowEnumerator.existingWindowIDs(),
            current: current,
            recentlyUsed: isRecentlyUsed
        )
        var byID: [CGWindowID: WindowInfo] = [:]
        for window in visible { byID[window.id] = window }
        let result = orderedIDs.compactMap { byID[$0] }

        logSnapshot(
            before: before, visible: visible, current: current,
            source: !queriedSystem && current != nil ? "pending" : (current == nil ? "none" : "system"),
            pendingAtOpen: pendingAtOpen
        )
        return result
    }

    /// Records a window the user chose in the switcher. Call it just before
    /// asking macOS to activate the window.
    func noteCommit(_ window: WindowInfo) {
        // Pending is recorded in both modes. In fixed mode it still anchors
        // the next open's pre-selection while the activation settles.
        pending = PendingCommit(pid: window.pid, windowID: window.id, now: now)
        promote(window.id, source: "commit")
    }

    /// The focused window as the system reports it: the frontmost app's
    /// Accessibility focused window. If that window isn't one we list (a
    /// palette or sheet, say), or the app doesn't support Accessibility, the
    /// app's front-most listed window is used instead. Nil when this app's own
    /// window is frontmost, or the frontmost app has no listed windows.
    private static func systemFocusedWindow(in visible: [WindowInfo]) -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard pid != getpid() else { return nil }
        if let id = WindowActivator.focusedWindowID(forPID: pid), visible.contains(where: { $0.id == id }) {
            return id
        }
        return visible.first(where: { $0.pid == pid })?.id
    }

    /// Promotes in recently-used mode only. In fixed mode positions never
    /// move. `source` only labels the diagnostic log line.
    private func promote(_ id: CGWindowID, source: String) {
        guard isRecentlyUsed else { return }
        let before = history.order
        history.promote(id)
        MRULog.info("promote \(MRULog.describe(id)) source=\(source) before=\(MRULog.describe(before)) after=\(MRULog.describe(history.order))")
    }

    @objc private func appDidActivate(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var axFocused: CGWindowID?
        let outcome = WindowFocus.onActivation(
            notifiedPID: pid,
            frontmostPID: frontmost,
            ownPID: getpid(),
            pending: pending,
            now: now
        ) {
            axFocused = WindowActivator.focusedWindowID(forPID: pid)
            return axFocused
        }
        if outcome.clearPending { pending = nil }

        MRULog.info(
            "didActivate pid=\(pid)(\(app.localizedName ?? "?")) frontmostNow=\(frontmost.map(String.init) ?? "nil")"
            + " axFocused=\(MRULog.describe(axFocused)) decision=\(outcome.decision) clearPending=\(outcome.clearPending)"
        )

        if case .promote(let id) = outcome.decision {
            promote(id, source: "didActivate")
        }
    }

    // MARK: - Diagnostics (no-ops unless MRULog is enabled)

    private func logSnapshot(
        before: [CGWindowID],
        visible: [WindowInfo],
        current: CGWindowID?,
        source: String,
        pendingAtOpen: PendingCommit?
    ) {
        guard MRULog.isEnabled else { return }
        MRULog.remember(visible)

        let zFront = visible.first?.id
        let focus = MRULog.actualFocus()
        let dropped = before.filter { !history.order.contains($0) }
        MRULog.info(
            "open mode=\(AppSettings.shared.windowOrder.rawValue)"
            + " current=\(MRULog.describe(current)) source=\(source)"
            + " pending=\(pendingAtOpen.map { "\(MRULog.describe($0.windowID)) live=\($0.isLive(at: now))" } ?? "nil")"
            + " zFront=\(MRULog.describe(zFront))"
            + " systemFocused=\(MRULog.describe(focus?.windowID)) frontmostApp=\(focus.map { "\($0.pid)(\($0.app))" } ?? "nil")"
            + " order=\(MRULog.describe(history.order))"
            + (dropped.isEmpty ? "" : " dropped=\(MRULog.describe(dropped))")
        )

        // These two are informational now. Neither feeds the selection any
        // more, but they show how often the old anchor would have been wrong.
        if let focused = focus?.windowID, focused != zFront {
            MRULog.info("zorder-lag zFront=\(MRULog.describe(zFront)) systemFocused=\(MRULog.describe(focused))")
        }
        if source == "pending", let focused = focus?.windowID, focused != current {
            MRULog.info("system still settling: using pending \(MRULog.describe(current)), system reports \(MRULog.describe(focused))")
        }

        // An invariant. In recently-used mode the current window must head
        // the list, or the pre-selection is wrong.
        if isRecentlyUsed, let current, history.order.first != current {
            MRULog.anomaly("head-not-current", "head=\(MRULog.describe(history.order.first)) current=\(MRULog.describe(current))")
        }
    }
}
