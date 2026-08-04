import AppKit
import CoreGraphics

/// Actions the low-level key handler reports up to the switcher.
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
final class HotKeyManager {

    weak var delegate: HotKeyManagerDelegate?

    // MARK: Configuration

    // The modifier and trigger key are read live from user settings on every
    // event, so rebinding in the Settings window takes effect instantly with no
    // need to reinstall the tap. Escape always cancels.
    private var modifier: CGEventFlags { AppSettings.shared.modifier.flag }
    private var triggerKeyCode: CGKeyCode { AppSettings.shared.triggerKey.keyCode }
    private let escapeKeyCode: CGKeyCode = 53

    // MARK: State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Whether the switch gesture is currently in progress (modifier down and
    /// switcher shown). Used to decide whether to consume Tab/Escape.
    private var gestureActive = false

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
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Called by the switcher when it closes, so we stop swallowing Tab.
    func gestureDidEnd() {
        gestureActive = false
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that runs too long or is interrupted; just
        // re-enable it and pass the event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let modifierHeld = flags.contains(modifier)

        switch type {
        case .flagsChanged:
            // The gesture ends the instant the modifier is released.
            if gestureActive && !modifierHeld {
                delegate?.hotKeyCommit()
                gestureActive = false
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

            // Trigger key while the modifier is held: begin or advance the
            // gesture and swallow the event so it doesn't reach the focused app.
            // (Swallowing is also what lets a Command binding override the
            // system app switcher.)
            if keyCode == triggerKeyCode && modifierHeld {
                gestureActive = true
                let reverse = flags.contains(.maskShift)
                delegate?.hotKeyCycle(reverse: reverse)
                return nil
            }

            // Escape during an active gesture cancels it.
            if keyCode == escapeKeyCode && gestureActive {
                delegate?.hotKeyCancel()
                gestureActive = false
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
