import AppKit
import ApplicationServices

/// Reports when the observed app moves keyboard focus between its own
/// windows, through Accessibility's `kAXFocusedWindowChangedNotification`.
///
/// NSWorkspace reports only app switches, so without this, ⌘` or a click on
/// a sibling window would never reach the history. Only one app is watched
/// at a time, the frontmost one, because only its focus changes matter.
/// `WindowOrderManager` retargets the observer on every activation, so it
/// costs one AXObserver no matter how many apps are running.
///
/// The callback fires on the main run loop.
final class FocusObserver {

    typealias Handler = (_ pid: pid_t, _ windowID: CGWindowID) -> Void

    private let handler: Handler
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    /// The app actually being observed: set only once registration succeeds.
    private(set) var observedPID: pid_t?
    /// The app we were last asked to observe, even if registration is still
    /// failing. Used so that a pending retry for an app we've moved on from
    /// gives up.
    private var wantedPID: pid_t?

    /// A newly launched app often can't answer Accessibility for a moment,
    /// so failing to register is retried a few times on a short back-off,
    /// rather than leaving the app unobserved until the next switch.
    private static let retryDelays: [TimeInterval] = [0.3, 1.0, 3.0]

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stopObserving()
    }

    /// Starts watching `pid`, replacing any app watched before. Asking for the
    /// app that is already watched, or already being retried, does nothing.
    func observe(pid: pid_t) {
        guard pid != wantedPID else { return }
        stopObserving()
        wantedPID = pid
        register(pid: pid, attempt: 0)
    }

    func stopObserving() {
        if let observer, let appElement {
            AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        appElement = nil
        observedPID = nil
        wantedPID = nil
    }

    private func register(pid: pid_t, attempt: Int) {
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.focusedWindowChanged(to: element)
        }
        let created = AXObserverCreate(pid, callback, &newObserver)
        guard created == .success, let newObserver else {
            retryOrGiveUp(pid: pid, attempt: attempt, error: created)
            return
        }

        let element = AXUIElementCreateApplication(pid)
        let added = AXObserverAddNotification(
            newObserver, element, kAXFocusedWindowChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard added == .success else {
            retryOrGiveUp(pid: pid, attempt: attempt, error: added)
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        observer = newObserver
        appElement = element
        observedPID = pid
        if attempt > 0 { MRULog.info("focus observer: pid \(pid) registered on retry \(attempt)") }
    }

    private func retryOrGiveUp(pid: pid_t, attempt: Int, error: AXError) {
        // An app that doesn't support the notification never will. For it,
        // in-app switches fall back to the check at the next open. Other
        // errors (most often cannotComplete while an app is still launching)
        // are worth another try.
        guard error != .notificationUnsupported, attempt < Self.retryDelays.count else {
            MRULog.info("focus observer: giving up on pid \(pid) after \(attempt + 1) attempt(s) (AXError \(error.rawValue))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
            // Still the app we want, and not registered in the meantime?
            guard let self, self.wantedPID == pid, self.observedPID == nil else { return }
            self.register(pid: pid, attempt: attempt + 1)
        }
    }

    private func focusedWindowChanged(to element: AXUIElement) {
        // Take the pid from the element itself rather than assuming it, so an
        // event that was already queued when the observer was retargeted can
        // never be credited to the new app.
        var elementPID: pid_t = 0
        guard
            let observed = observedPID,
            AXUIElementGetPid(element, &elementPID) == .success,
            elementPID == observed,
            let id = WindowActivator.windowID(of: element)
        else { return }
        handler(observed, id)
    }
}
