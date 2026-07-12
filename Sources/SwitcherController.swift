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
        model.thumbnails = [:]

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
            // Ignore late results from a previous, already-dismissed gesture.
            guard self?.isVisible == true else { return }
            self?.model.thumbnails[id] = image
        }
    }

    @objc private func cardClicked(_ note: Notification) {
        guard isVisible, let index = note.object as? Int,
              model.windows.indices.contains(index) else { return }
        model.selectedIndex = index
        hotKeyCommit()
    }
}
