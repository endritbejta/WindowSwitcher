import AppKit
import CoreGraphics

/// Checks and requests the two macOS privacy permissions this app needs, and
/// deep-links the user to the right System Settings pane for each.
///
///   * Accessibility  — required to install the key-event tap (read the
///     Option+Tab gesture) and to raise/focus another app's window.
///   * Screen Recording — required to capture live window thumbnails and to
///     read window titles from CoreGraphics.
enum PermissionsManager {

    /// True when the app is a trusted Accessibility client. Pass `prompt: true`
    /// to also show the system's "grant access" dialog.
    static func hasAccessibility(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// True when Screen Recording is granted. `CGPreflight...` only checks;
    /// `CGRequest...` triggers the system prompt the first time.
    static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Both permissions present?
    static var allGranted: Bool {
        hasAccessibility() && hasScreenRecording()
    }

    // MARK: Deep links into System Settings

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
