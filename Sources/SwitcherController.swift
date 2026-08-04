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
        let windows = windowOrder.orderedWindows()
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
        // Position of the currently-focused window in the list (0 if unknown).
        let currentIndex = windows.firstIndex { $0.id == windowOrder.frontWindowID } ?? 0
        let delta = reverse ? -1 : 1
        model.selectedIndex = ((currentIndex + delta) % count + count) % count

        if panel == nil {
            let hosting = NSHostingView(rootView: SwitcherView(model: model))
            panel = SwitcherPanel(rootView: hosting)
        }
        panel?.presentCentered()
        isVisible = true

        captureThumbnails(for: windows)
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
        ThumbnailProvider.captureThumbnails(for: windows.map(\.id)) { [weak self] id, image in
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
