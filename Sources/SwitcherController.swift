import AppKit
import SwiftUI

/// Orchestrates the whole switch gesture: it owns the MRU manager, the hot-key
/// tap, the overlay panel and the UI model, and wires the low-level key events
/// to selection changes and window activation.
final class SwitcherController: HotKeyManagerDelegate {

    private let windowOrder = WindowOrderManager()
    private let hotKeys = HotKeyManager()
    private let model = SwitcherModel()

    private var panel: SwitcherPanel?
    /// Kept so each gesture can hand the SwiftUI root the display it is about
    /// to appear on, before the panel measures itself.
    private var hostingView: NSHostingView<SwitcherView>?
    private var isVisible = false

    /// Thumbnails from previous gestures, keyed by window id. Unlike
    /// `model.thumbnails` (which is wiped and rebuilt on every `open()`), this
    /// persists across opens so that flipping back to a window you looked at
    /// moments ago shows its last-known preview immediately instead of the
    /// icon placeholder while a fresh capture is in flight. Pruned to the
    /// windows that still exist each time, so it can't grow unbounded.
    private var thumbnailCache: [CGWindowID: NSImage] = [:]

    init() {
        hotKeys.delegate = self
        // Commit when a card is clicked with the mouse.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cardClicked(_:)),
            name: .switcherCardClicked,
            object: nil
        )
    }

    /// Install the global shortcut. Returns false if Accessibility permission is
    /// missing (the event tap can't be created).
    @discardableResult
    func start() -> Bool {
        hotKeys.start()
    }

    func stop() {
        hotKeys.stop()
    }

    // MARK: - HotKeyManagerDelegate

    func hotKeyCycle(reverse: Bool) {
        if !isVisible {
            open(reverse: reverse)
        } else {
            moveSelection(reverse: reverse)
        }
    }

    func hotKeyCommit() {
        guard isVisible else { return }
        let selected = model.windows.indices.contains(model.selectedIndex)
            ? model.windows[model.selectedIndex] : nil
        close()
        if let selected {
            windowOrder.markUsed(selected.id)
            WindowActivator.activate(selected)
        }
    }

    func hotKeyCancel() {
        close()
    }

    // MARK: - Presentation

    /// Snapshot the windows, show the overlay, and pre-select the window next
    /// to the currently-focused one — a single forward tap lands on the neighbour
    /// after it, a reverse (Shift) tap on the one before. This is computed
    /// relative to the focused window so it behaves correctly in both fixed and
    /// recently-used ordering.
    private func open(reverse: Bool) {
        let allWindows = windowOrder.orderedWindows()
        guard !allWindows.isEmpty else { return }

        // Which display the overlay belongs on is decided before the list is
        // built, because in per-display mode it also decides what's *in* the
        // list.
        guard let screen = targetScreen(among: allWindows) else { return }
        let windows = scoped(allWindows, to: screen)
        guard !windows.isEmpty else { return }

        model.windows = windows

        // Drop cached previews for windows that no longer exist, then seed
        // the model from what's left — instant redisplay for anything we've
        // already captured, icon placeholder only for windows we've never
        // seen before. The capture kicked off below refreshes every entry
        // regardless, so a stale cached preview only lives on screen for the
        // moment it takes the fresh one to land.
        let liveIDs = Set(windows.map(\.id))
        thumbnailCache = thumbnailCache.filter { liveIDs.contains($0.key) }
        model.thumbnails = thumbnailCache

        let count = windows.count
        let delta = reverse ? -1 : 1
        if let currentIndex = windows.firstIndex(where: { $0.id == windowOrder.frontWindowID }) {
            model.selectedIndex = ((currentIndex + delta) % count + count) % count
        } else {
            // The focused window isn't in this list — normal in per-display
            // mode, where the pointer can be on one monitor while the keyboard
            // focus is on another. Starting from an assumed index 0 would then
            // skip the first entry on a forward tap, so land on the end the
            // gesture is heading towards instead.
            model.selectedIndex = reverse ? count - 1 : 0
        }

        // Tell the view how much room this display gives it, then let the
        // panel size itself to the result. Passed through the root view rather
        // than the observable model so the new layout is resolved by the time
        // `present(on:)` reads the fitting size.
        let rootView = SwitcherView(
            model: model,
            availableSize: CGSize(
                width: screen.visibleFrame.width - SwitcherPanel.screenMargin * 2,
                height: screen.visibleFrame.height - SwitcherPanel.screenMargin * 2
            ),
            // Badges only earn their place when the list actually spans screens.
            showsDisplayBadges: NSScreen.screens.count > 1
                && AppSettings.shared.displayScope == .allDisplays
        )

        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hosting = NSHostingView(rootView: rootView)
            hostingView = hosting
            panel = SwitcherPanel(rootView: hosting)
        }
        panel?.present(on: screen)
        isVisible = true

        captureThumbnails(for: windows)
    }

    // MARK: - Multi-display placement

    /// The display the overlay should appear on, per `AppSettings`.
    ///
    /// Each mode falls through to the others rather than to a hard-coded
    /// screen: the pointer can be in the dead zone between two monitors, and
    /// the focused window's display is unknown for the moment after one is
    /// unplugged. Landing on the wrong screen is recoverable; not showing at
    /// all is not.
    private func targetScreen(among windows: [WindowInfo]) -> NSScreen? {
        switch AppSettings.shared.overlayDisplay {
        case .pointer:
            return NSScreen.screenWithMouse ?? focusedWindowScreen(among: windows) ?? DisplayLayout.menuBarScreen
        case .activeWindow:
            return focusedWindowScreen(among: windows) ?? NSScreen.screenWithMouse ?? DisplayLayout.menuBarScreen
        case .main:
            return DisplayLayout.menuBarScreen ?? NSScreen.screenWithMouse
        }
    }

    /// The display showing the window that currently has keyboard focus.
    private func focusedWindowScreen(among windows: [WindowInfo]) -> NSScreen? {
        guard
            let front = windows.first(where: { $0.id == windowOrder.frontWindowID }),
            let id = front.display?.id
        else { return nil }
        return DisplayLayout.screen(for: id)
    }

    /// Narrows the list to `screen` when the user asked for per-display
    /// switching. Falls back to the full list if that display has nothing on
    /// it — an empty overlay would swallow the gesture and leave the shortcut
    /// looking broken.
    private func scoped(_ windows: [WindowInfo], to screen: NSScreen) -> [WindowInfo] {
        guard
            AppSettings.shared.displayScope == .activeDisplay,
            NSScreen.screens.count > 1,
            let id = screen.displayID
        else { return windows }
        let onScreen = windows.filter { $0.display?.id == id }
        return onScreen.isEmpty ? windows : onScreen
    }

    private func moveSelection(reverse: Bool) {
        let count = model.windows.count
        guard count > 0 else { return }
        let delta = reverse ? -1 : 1
        model.selectedIndex = ((model.selectedIndex + delta) % count + count) % count
    }

    private func close() {
        panel?.orderOut(nil)
        isVisible = false
        hotKeys.gestureDidEnd()
    }

    // MARK: - Thumbnails

    /// Capture window previews via ScreenCaptureKit, publishing results back on
    /// the main actor as they arrive so the grid fills in progressively.
    private func captureThumbnails(for windows: [WindowInfo]) {
        ThumbnailProvider.captureThumbnails(for: windows) { [weak self] id, image in
            guard let self, self.isVisible else { return }
            self.model.thumbnails[id] = image
            self.thumbnailCache[id] = image
        }
    }

    @objc private func cardClicked(_ note: Notification) {
        guard isVisible, let index = note.object as? Int,
              model.windows.indices.contains(index) else { return }
        model.selectedIndex = index
        hotKeyCommit()
    }
}
