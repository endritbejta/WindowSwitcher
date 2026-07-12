import AppKit
import SwiftUI

/// Guides the user through granting permissions.
///
/// Design notes learned the hard way:
///   * Only **Accessibility** is required to run the switcher (event tap +
///     window focus). We start the app the moment it is granted.
///   * **Screen Recording** is optional — without it the switcher simply shows
///     app icons instead of live thumbnails.
///   * `CGPreflightScreenCaptureAccess()` (and, to a lesser extent, the
///     Accessibility trust check) often stay stale inside a running process
///     after you toggle the permission. So this window does **not** block on
///     them — it offers a prominent "Restart App" button, because a relaunch is
///     what actually makes macOS apply a freshly-granted permission.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private let onAccessibilityReady: () -> Void
    private let onRestart: () -> Void
    private var timer: Timer?
    private var startedSwitcher = false
    private let model = PermissionsViewModel()

    init(onAccessibilityReady: @escaping () -> Void, onRestart: @escaping () -> Void) {
        self.onAccessibilityReady = onAccessibilityReady
        self.onRestart = onRestart

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Window Switcher — Setup"
        window.center()
        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(
            rootView: PermissionsView(model: model, onRestart: onRestart)
        )

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Poll the current permission state and start the switcher as soon as
    /// Accessibility is available. Does not auto-close, so the user can still
    /// reach the Screen Recording toggle and the Restart button.
    private func refresh() {
        model.hasAccessibility = PermissionsManager.hasAccessibility()
        model.hasScreenRecording = PermissionsManager.hasScreenRecording()

        if model.hasAccessibility && !startedSwitcher {
            startedSwitcher = true
            model.switcherActive = true
            onAccessibilityReady()
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

final class PermissionsViewModel: ObservableObject {
    @Published var hasAccessibility = false
    @Published var hasScreenRecording = false
    /// True once the event tap is running (Accessibility granted).
    @Published var switcherActive = false
}

private struct PermissionsView: View {
    @ObservedObject var model: PermissionsViewModel
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up Window Switcher")
                    .font(.system(size: 20, weight: .semibold))
                Text("macOS requires your approval for the APIs the switcher uses.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(
                title: "Accessibility",
                badge: "Required",
                badgeColor: .blue,
                detail: "Read the shortcut and focus the selected window.",
                granted: model.hasAccessibility,
                action: PermissionsManager.openAccessibilitySettings
            )

            permissionRow(
                title: "Screen Recording",
                badge: "Optional — live previews",
                badgeColor: .secondary,
                detail: "Without it the switcher still works, showing app icons instead of thumbnails.",
                granted: model.hasScreenRecording,
                action: {
                    PermissionsManager.requestScreenRecording()
                    PermissionsManager.openScreenRecordingSettings()
                }
            )

            // The key to "I granted it but nothing happened": relaunch.
            VStack(alignment: .leading, spacing: 8) {
                Text("After turning a permission on, restart the app so macOS applies it — Screen Recording only takes effect after a restart.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRestart) {
                    Label("Restart App", systemImage: "arrow.clockwise")
                }
                .controlSize(.large)
            }

            Divider()

            // Live status.
            HStack(spacing: 8) {
                Image(systemName: model.switcherActive ? "checkmark.circle.fill" : "hourglass")
                    .foregroundStyle(model.switcherActive ? Color.green : Color.secondary)
                if model.switcherActive {
                    Text("Switcher is active — press \(AppSettings.shared.shortcutDisplay). You can close this window.")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Waiting for Accessibility…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(28)
        .frame(width: 480, height: 440, alignment: .topLeading)
    }

    private func permissionRow(
        title: String,
        badge: String,
        badgeColor: Color,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(badgeColor.opacity(0.15)))
                        .foregroundStyle(badgeColor)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button("Open Settings", action: action)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}
