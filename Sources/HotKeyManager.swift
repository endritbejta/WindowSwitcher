import AppKit
import CoreGraphics

/// Actions the low-level key handler reports up to the switcher. Every call
/// is delivered asynchronously on the main queue, in the order the events
/// happened, and never from inside the event-tap callback.
protocol HotKeyManagerDelegate: AnyObject {
    /// Trigger key pressed while the modifier is held. `reverse` is true when
    /// Shift is also held (cycle backwards).
    func hotKeyCycle(reverse: Bool)
    /// The modifier was released — commit to the current selection.
    func hotKeyCommit()
    /// Escape pressed — dismiss without switching.
    func hotKeyCancel()
}

/// Captures the global switch shortcut with a CGEvent tap.
///
/// A plain global hot-key API (like Carbon's `RegisterEventHotKey`) can tell us
/// when Tab is pressed, but not when the modifier is *released* — which is how
/// Windows Alt+Tab commits the selection. An event tap sees the raw keyDown and
/// flagsChanged stream, so we can both intercept Tab and notice the moment
/// Option lets go.
///
/// The modifier and trigger key are configurable in Settings (default
/// Command+Tab); whichever is chosen, this tap swallows the key so it fully
/// replaces whatever system behavior is normally bound to it.
///
/// **The callback only decides.** The tap sits in front of every keystroke
/// in the session, and macOS disables a tap that is slow to answer. A
/// disabled tap can drop the very modifier release that ends a gesture. So
/// the callback only works out, from the key code and flags, whether to
/// swallow the event. That is pure and takes microseconds. Everything else
/// (enumerating windows, laying out the overlay, Accessibility calls into
/// other apps) is queued to run after the callback has returned.
///
/// **A lost release is recovered.** The gesture logic lives in
/// `GestureTracker`. If a release is never delivered, the live modifier
/// state is checked when the tap is re-enabled, on the next keystroke, and
/// on a short timer that runs only while a gesture is in progress.
final class HotKeyManager {

    weak var delegate: HotKeyManagerDelegate?

    // MARK: Configuration

    // The modifier and trigger key are read live from user settings on every
    // event, so rebinding in the Settings window takes effect instantly with no
    // need to reinstall the tap. Escape always cancels.
    private var modifier: CGEventFlags { AppSettings.shared.modifier.flag }
    private var triggerKeyCode: CGKeyCode { AppSettings.shared.triggerKey.keyCode }

    /// How often the live modifier state is checked while a gesture is in
    /// progress. This is only the backstop for a lost release, so it doesn't
    /// need to be fast. Nothing polls when no gesture is active.
    private static let releaseCheckInterval: TimeInterval = 0.2

    // MARK: State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var gesture = GestureTracker(triggerKeyCode: AppSettings.shared.triggerKey.keyCode)
    private var releaseCheckTimer: Timer?

    /// Install the event tap. Requires Accessibility permission; returns false
    /// if the tap could not be created (permission missing).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // The C callback receives `self` back through the refcon pointer.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        gesture.end()
        updateReleaseCheck()
    }

    /// Called by the switcher when it ends the gesture itself (a card was
    /// clicked), so Tab and Escape stop being swallowed.
    ///
    /// The switcher's own `close()` deliberately does not call this. By the
    /// time a queued commit runs, the user may already have started the next
    /// gesture, and resetting then would leave that gesture unable to commit.
    func gestureDidEnd() {
        gesture.end()
        updateReleaseCheck()
    }

    // MARK: Event handling (runs inside the tap callback — keep it cheap)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that runs too long or is interrupted.
        // Re-enable it, then check whether a release was lost while it was
        // off.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MRULog.anomaly(
                "tap-disabled",
                "\(type == .tapDisabledByTimeout ? "timeout" : "userInput") gestureActive=\(gesture.isActive)"
            )
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            resyncWithLiveModifier(reason: "tap re-enabled")
            return Unmanaged.passUnretained(event)
        }

        gesture = gesture.withTriggerKeyCode(triggerKeyCode)
        let modifierHeld = event.flags.contains(modifier)

        switch type {
        case .flagsChanged:
            send(gesture.flagsChanged(modifierHeld: modifierHeld))
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let wasActive = gesture.isActive
            let result = gesture.keyDown(
                keyCode: keyCode,
                modifierHeld: modifierHeld,
                shiftHeld: event.flags.contains(.maskShift)
            )
            if wasActive, result.action == .commit {
                MRULog.anomaly("missed-release", "recovered on keyDown \(keyCode)")
            }
            send(result.action)
            return result.swallow ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Hands an action to the switcher after the callback returns. Blocks on
    /// the main queue run in FIFO order, so a gesture's cycle, commit and
    /// cancel arrive in the order the keys were pressed.
    private func send(_ action: GestureTracker.Action?) {
        updateReleaseCheck()
        guard let action else { return }
        DispatchQueue.main.async { [weak self] in
            guard let delegate = self?.delegate else { return }
            switch action {
            case .cycle(let reverse): delegate.hotKeyCycle(reverse: reverse)
            case .commit:             delegate.hotKeyCommit()
            case .cancel:             delegate.hotKeyCancel()
            }
        }
    }

    // MARK: Lost-release recovery

    /// Whether the gesture's modifier is down right now, from the window
    /// server's own state rather than from any event we were (or weren't)
    /// delivered.
    private var liveModifierHeld: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(modifier)
    }

    private func resyncWithLiveModifier(reason: String) {
        guard gesture.isActive else { return }
        if let action = gesture.resync(modifierHeld: liveModifierHeld) {
            MRULog.anomaly("missed-release", "recovered: \(reason)")
            send(action)
        }
    }

    /// Runs the release check only while a gesture is in progress.
    private func updateReleaseCheck() {
        if gesture.isActive {
            guard releaseCheckTimer == nil else { return }
            let timer = Timer(timeInterval: Self.releaseCheckInterval, repeats: true) { [weak self] _ in
                self?.resyncWithLiveModifier(reason: "release check timer")
            }
            timer.tolerance = Self.releaseCheckInterval / 2
            RunLoop.main.add(timer, forMode: .common)
            releaseCheckTimer = timer
        } else {
            releaseCheckTimer?.invalidate()
            releaseCheckTimer = nil
        }
    }
}
