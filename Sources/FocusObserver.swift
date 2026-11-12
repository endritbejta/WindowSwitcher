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
    private(set) var observedPID: pid_t?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stopObserving()
    }

    /// Starts watching `pid`, replacing any app watched before. Watching the
    /// same app again does nothing.
    func observe(pid: pid_t) {
        guard pid != observedPID else { return }
        stopObserving()

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.focusedWindowChanged(to: element)
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else {
            MRULog.info("focus observer: could not observe pid \(pid)")
            return
        }

        let element = AXUIElementCreateApplication(pid)
        let added = AXObserverAddNotification(
            newObserver, element, kAXFocusedWindowChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        // Some apps don't support Accessibility notifications. Their
        // in-app switches then fall back to the check at the next open.
        guard added == .success else {
            MRULog.info("focus observer: pid \(pid) does not support focus notifications (\(added.rawValue))")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        observer = newObserver
        appElement = element
        observedPID = pid
    }

    func stopObserving() {
        if let observer, let appElement {
            AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        appElement = nil
        observedPID = nil
    }

    private func focusedWindowChanged(to element: AXUIElement) {
        guard let pid = observedPID, let id = WindowActivator.windowID(of: element) else { return }
        handler(pid, id)
    }
}
