import AppKit
import ScreenCaptureKit

/// Renders downscaled preview images for windows using ScreenCaptureKit — the
/// modern, non-deprecated capture API (macOS 14+).
///
/// We capture lazily and only while the switcher is open, so there is zero
/// ongoing cost when idle. Shareable content is fetched once per gesture and
/// each window is then captured directly at preview size, keeping both CPU and
/// memory low (a handful of ~320px stills).
enum ThumbnailProvider {

    /// Longest edge of the generated preview, in points. Small enough to stay
    /// cheap, large enough to recognise the window's contents.
    private static let maxDimension: CGFloat = 320

    /// Capture previews for the given windows in a single pass. `onImage` is
    /// invoked on the **main actor** as each preview finishes, so results can be
    /// published to the UI progressively. Windows that can't be captured
    /// (closed, or permission missing) are simply skipped.
    static func captureThumbnails(
        for windowIDs: [CGWindowID],
        onImage: @escaping (CGWindowID, NSImage) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            // One shareable-content query covers every window we need.
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            ) else { return }

            // Index the SCWindows by their CGWindowID for fast lookup.
            var scWindowsByID: [CGWindowID: SCWindow] = [:]
            for scWindow in content.windows { scWindowsByID[scWindow.windowID] = scWindow }

            for id in windowIDs {
                guard let scWindow = scWindowsByID[id] else { continue }
                guard let image = await capture(scWindow) else { continue }
                await MainActor.run { onImage(id, image) }
            }
        }
    }

    /// Capture one window at preview resolution.
    private static func capture(_ scWindow: SCWindow) async -> NSImage? {
        // A filter scoped to just this window — no desktop, no other windows.
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        // Ask ScreenCaptureKit to render directly at preview size (preserving
        // aspect ratio) so we never allocate a full-resolution bitmap.
        let width = scWindow.frame.width
        let height = scWindow.frame.height
        guard width > 1, height > 1 else { return nil }
        let scale = min(1, maxDimension / max(width, height))

        let config = SCStreamConfiguration()
        config.width = max(1, Int(width * scale))
        config.height = max(1, Int(height * scale))
        config.showsCursor = false
        config.ignoreGlobalClipDisplay = true

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
