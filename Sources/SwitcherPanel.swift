import AppKit
import SwiftUI

/// A borderless, non-activating panel that hosts the SwiftUI switcher.
///
/// `.nonactivatingPanel` is essential: showing the overlay must not steal key
/// focus from the app the user is holding Option over, otherwise releasing
/// Option wouldn't be seen as ending the gesture and the wrong app would end up
/// active. The panel floats above everything, including full-screen apps.
final class SwitcherPanel: NSPanel {

    init(rootView: NSView) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu                 // above normal windows and the Dock
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // Appear on every Space and over full-screen windows.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = rootView
    }

    // Borderless panels normally can't become key; the switcher never needs to,
    // so we keep it non-key to preserve the underlying app's focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Size to fit the hosted SwiftUI content and center on the screen with the
    /// mouse (the display the user is looking at).
    func presentCentered() {
        layoutIfNeeded()
        let fitting = contentView?.fittingSize ?? NSSize(width: 400, height: 200)
        setContentSize(fitting)

        let screen = NSScreen.screenWithMouse ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(
                x: visible.midX - fitting.width / 2,
                y: visible.midY - fitting.height / 2
            )
            setFrameOrigin(origin)
        }
        orderFrontRegardless()
    }
}

extension NSScreen {
    /// The screen currently containing the mouse cursor.
    static var screenWithMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}
