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

    /// Gap kept between the overlay and the edges of its display, so the panel
    /// reads as floating on that screen rather than filling it.
    static let screenMargin: CGFloat = 24

    /// Size to fit the hosted SwiftUI content and centre it on `screen`.
    ///
    /// The clamp matters on a mixed setup: the content is measured from the
    /// SwiftUI view, which knows nothing about where it is going to land, so
    /// without it a grid laid out comfortably for a 27" monitor would hang off
    /// both edges of a laptop display. `SwitcherView` is told the same budget
    /// and lays out inside it, so the clamp should never actually bite — it is
    /// the backstop for the frame where it hasn't caught up yet.
    func present(on screen: NSScreen) {
        // NSHostingView resolves its size lazily; force the pass so the
        // fitting size we read below reflects this gesture's layout and not
        // the previous one's.
        contentView?.layoutSubtreeIfNeeded()

        let visible = screen.visibleFrame
        let budget = NSSize(
            width: max(120, visible.width - Self.screenMargin * 2),
            height: max(120, visible.height - Self.screenMargin * 2)
        )
        var fitting = contentView?.fittingSize ?? NSSize(width: 400, height: 200)
        fitting.width = min(fitting.width, budget.width)
        fitting.height = min(fitting.height, budget.height)

        setContentSize(fitting)
        // Placed by frame rather than `center()`, which would always use the
        // main display and ignore `screen` entirely.
        setFrameOrigin(NSPoint(
            x: visible.midX - fitting.width / 2,
            y: visible.midY - fitting.height / 2
        ))
        orderFrontRegardless()
    }
}
