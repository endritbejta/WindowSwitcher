/// The hold-modifier-and-tap gesture as a small state machine, kept free of
/// CGEvent so it can be unit-tested (`./build.sh test`).
///
/// `HotKeyManager` feeds it every relevant event from the tap. It returns
/// whether to swallow the event and what the switcher should do. Its only
/// state is whether a gesture is in progress, and every input that can end a
/// gesture ends it here, so the state can't get stuck.
///
/// A gesture normally ends with a `flagsChanged` showing the modifier
/// released. That event can be lost, for example when macOS disables the tap
/// while the user is releasing the key. `resync` and `keyDown` both detect
/// that from the live modifier state and commit then, as the release would
/// have done.
struct GestureTracker: Equatable {

    enum Action: Equatable {
        case cycle(reverse: Bool)
        case commit
        case cancel
    }

    struct Result: Equatable {
        /// Drop the event so it never reaches the focused app.
        var swallow: Bool
        var action: Action?
    }

    let triggerKeyCode: UInt16
    let escapeKeyCode: UInt16

    private(set) var isActive = false

    init(triggerKeyCode: UInt16, escapeKeyCode: UInt16 = 53) {
        self.triggerKeyCode = triggerKeyCode
        self.escapeKeyCode = escapeKeyCode
    }

    /// The trigger key can be rebound while the app runs. A gesture already
    /// in progress keeps going, using the new key.
    func withTriggerKeyCode(_ code: UInt16) -> GestureTracker {
        guard code != triggerKeyCode else { return self }
        var copy = GestureTracker(triggerKeyCode: code, escapeKeyCode: escapeKeyCode)
        copy.isActive = isActive
        return copy
    }

    mutating func keyDown(keyCode: UInt16, modifierHeld: Bool, shiftHeld: Bool) -> Result {
        // The trigger key with the modifier held starts or advances the
        // gesture. Swallowing it is also what lets a Command binding replace
        // the system app switcher.
        if keyCode == triggerKeyCode && modifierHeld {
            isActive = true
            return Result(swallow: true, action: .cycle(reverse: shiftHeld))
        }
        // Escape always means "dismiss", even after a lost release. The
        // overlay is still on screen, and a user reaching for Escape wants it
        // gone without switching. So it is checked before the lost-release
        // commit below, and swallowed, as in the normal case.
        if keyCode == escapeKeyCode && isActive {
            isActive = false
            return Result(swallow: true, action: .cancel)
        }
        // A gesture in progress with the modifier already up means its
        // release was lost. Commit as the release would have, and let this
        // key through, since it isn't part of the gesture.
        if isActive && !modifierHeld {
            isActive = false
            return Result(swallow: false, action: .commit)
        }
        return Result(swallow: false, action: nil)
    }

    /// A modifier went down or up. Releasing the gesture's modifier commits.
    mutating func flagsChanged(modifierHeld: Bool) -> Action? {
        resync(modifierHeld: modifierHeld)
    }

    /// Checks the live modifier state against the gesture. It is called
    /// after the tap is re-enabled, and periodically while a gesture is in
    /// progress, in case a release was never delivered.
    mutating func resync(modifierHeld: Bool) -> Action? {
        guard isActive && !modifierHeld else { return nil }
        isActive = false
        return .commit
    }

    /// The switcher ended the gesture itself, for example when a card was
    /// clicked.
    mutating func end() {
        isActive = false
    }
}
