import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.example.windowswitcher", category: "permissions")

/// Checks and requests the two macOS privacy permissions this app needs, and
/// deep-links the user to the right System Settings pane for each.
///
///   * Accessibility  — required to install the key-event tap (read the
///     Option+Tab gesture) and to raise/focus another app's window.
///   * Screen Recording — required to capture live window thumbnails and to
///     read window titles from CoreGraphics.
///
/// Whether a grant can *stick* is a separate question, answered by
/// `AppIdentity` and `PermissionSetup` — see the notes there.
enum PermissionsManager {

    /// True when the app is a trusted Accessibility client. Pass `prompt: true`
    /// to also show the system's "grant access" dialog — this is also what
    /// gets the app **listed** in Privacy & Security → Accessibility in the
    /// first place; a silent, non-prompting check does not.
    static func hasAccessibility(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log.notice("hasAccessibility(prompt: \(prompt)) -> \(trusted)")
        return trusted
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

    // MARK: "I granted it and nothing happened" detection

    /// When the user was last sent to the Accessibility pane.
    private static var settingsOpenedAt: Date?

    /// How long the user is given to flip the toggle before we conclude that
    /// flipping it is not going to help.
    private static let stuckThreshold: TimeInterval = 12

    /// True when the user has visited the Accessibility pane and we are *still*
    /// not trusted a while later. At that point the problem is not that they
    /// haven't granted it — it's that the grant cannot apply to this copy, so
    /// the repair actions need to be offered rather than more instructions.
    ///
    /// This is deliberately a time-based heuristic and not the only route to the
    /// repair: `AppIdentity.identityChangedSinceLastLaunch` catches the same
    /// condition up front when it can be proven, and the reset action stays
    /// reachable regardless.
    static var looksStuck: Bool {
        guard let opened = settingsOpenedAt else { return false }
        return Date().timeIntervalSince(opened) > stuckThreshold && !hasAccessibility()
    }

    // MARK: Deep links into System Settings

    static func openAccessibilitySettings() {
        settingsOpenedAt = Date()
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
