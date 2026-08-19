import AppKit
import SwiftUI

/// Guides the user through granting permissions — and, when a grant cannot
/// stick, fixes the reason first.
///
/// Design notes learned the hard way:
///   * Only **Accessibility** is required to run the switcher (event tap +
///     window focus). We start the app the moment it is granted.
///   * **Screen Recording** is optional — without it the switcher simply shows
///     app icons instead of live thumbnails.
///   * `CGPreflightScreenCaptureAccess()` (and, to a lesser extent, the
///     Accessibility trust check) often stay stale inside a running process
///     after you toggle the permission, so a relaunch is what actually makes
///     macOS apply a freshly-granted permission.
///   * Telling the user to toggle the switch is useless when macOS cannot
///     associate the grant with this copy of the app — a translocated bundle or
///     a changed code identity. `PermissionSetup.blockers()` finds those cases
///     and this window puts the actual repair in front of the user, because no
///     amount of toggling will resolve them.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// Asks the delegate to start the switcher. Returns whether the event tap
    /// is now running — a `false` means we keep trying on the next poll, since
    /// tap creation can fail even in the moment after the grant lands.
    private let onAccessibilityReady: () -> Bool
    private let onRestart: () -> Void
    private var timer: Timer?
    private let model = PermissionsViewModel()

    init(onAccessibilityReady: @escaping () -> Bool, onRestart: @escaping () -> Void) {
        self.onAccessibilityReady = onAccessibilityReady
        self.onRestart = onRestart

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
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

    /// Poll permission state, re-evaluate what is blocking a durable grant, and
    /// start the switcher as soon as Accessibility is available. Does not
    /// auto-close, so the user can still reach the Screen Recording toggle.
    private func refresh() {
        model.hasAccessibility = PermissionsManager.hasAccessibility()
        model.hasScreenRecording = PermissionsManager.hasScreenRecording()
        model.blockers = PermissionSetup.blockers()
        model.identitySummary = AppIdentity.signing.shortDescription

        // Keep trying until the tap is actually installed, not just until the
        // permission reads as granted.
        if model.hasAccessibility && !model.switcherActive {
            model.switcherActive = onAccessibilityReady()
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
    /// True once the event tap is running (Accessibility granted and installed).
    @Published var switcherActive = false
    /// Reasons a grant cannot stick, worst first.
    @Published var blockers: [PermissionSetup.Blocker] = []
    /// Human-readable signing state, shown in the diagnostics footer.
    @Published var identitySummary = ""
    /// Message from a repair that could not complete on its own.
    @Published var repairError: String?
    /// A repair is in flight (the app is about to relaunch).
    @Published var isRepairing = false
}

private struct PermissionsView: View {
    @ObservedObject var model: PermissionsViewModel
    let onRestart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                // Anything that would make a grant fail comes first: fixing the
                // permission itself is pointless while one of these stands.
                ForEach(model.blockers, id: \.self) { blocker in
                    blockerCard(blocker)
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

                // Offered whenever Accessibility is missing, with no cleverness
                // about whether we can *prove* a stale entry exists. An older
                // install of the app leaves an entry bound to its old code
                // identity, and on a Mac where this copy has never worked there
                // is nothing recorded to compare against — so gating the repair
                // on proof hid it in exactly the case that needs it. Resetting a
                // grant that was never there costs nothing.
                if !model.hasAccessibility {
                    resetEscapeHatch
                }

                if let error = model.repairError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                restartRow

                Divider()

                statusRow
                diagnosticsFooter
            }
            .padding(28)
            .frame(width: 520, alignment: .topLeading)
        }
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up Window Switcher")
                .font(.system(size: 20, weight: .semibold))
            Text("macOS requires your approval for the APIs the switcher uses.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A problem that prevents the grant from applying, with its one-click fix.
    private func blockerCard(_ blocker: PermissionSetup.Blocker) -> some View {
        let tint: Color = blocker.isFatal ? .orange : .secondary
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: blocker.isFatal ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(tint)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 6) {
                Text(blocker.title).font(.system(size: 14, weight: .medium))
                Text(blocker.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = blocker.actionTitle {
                    Button(actionTitle) { perform(blocker) }
                        .disabled(model.isRepairing)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.10)))
    }

    /// Always-available way out of the "the toggle is on but the app disagrees"
    /// deadlock, for the cases the checks above can't prove.
    private var resetEscapeHatch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Turned it on and nothing happened?")
                .font(.system(size: 14, weight: .medium))
            Text("""
                If an older version of Window Switcher was ever installed, macOS is still holding \
                that copy's permission entry — the switch reads as on but applies to the old app, \
                so this one is never trusted. This removes those entries and restarts, letting you \
                grant it once more from a clean slate.
                """)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset Permissions & Restart") { resetGrants() }
                .disabled(model.isRepairing)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.10)))
    }

    private var restartRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("After turning a permission on, restart the app so macOS applies it — Screen Recording only takes effect after a restart.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onRestart) {
                Label("Restart App", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
            .disabled(model.isRepairing)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.switcherActive ? "checkmark.circle.fill" : "hourglass")
                .foregroundStyle(model.switcherActive ? Color.green : Color.secondary)
            if model.switcherActive {
                Text("Switcher is active — press \(AppSettings.shared.shortcutDisplay). You can close this window.")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Waiting for Accessibility…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Shows what the permission is actually pinned to, so a future "it broke
    /// again" is diagnosable instead of guesswork.
    private var diagnosticsFooter: some View {
        HStack(spacing: 6) {
            Text("Identity: \(model.identitySummary)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Copy Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AppIdentity.describe(), forType: .string)
            }
            .buttonStyle(.link)
            .font(.system(size: 10))
        }
    }

    // MARK: Repair actions

    private func perform(_ blocker: PermissionSetup.Blocker) {
        switch blocker {
        case .translocated, .notInstalled:
            model.isRepairing = true
            model.repairError = nil
            PermissionSetup.installToApplications { result in
                DispatchQueue.main.async { apply(result) }
            }
        case .staleGrant:
            resetGrants()
        case .unstableIdentity:
            break   // Fixed by running ./setup-signing.sh, not from here.
        }
    }

    private func resetGrants() {
        model.isRepairing = true
        model.repairError = nil
        PermissionSetup.resetGrantsAndRelaunch { result in
            DispatchQueue.main.async { apply(result) }
        }
    }

    private func apply(_ result: PermissionSetup.RepairResult) {
        switch result {
        case .relaunching:
            break   // The process is on its way out; leave the UI as-is.
        case .failed(let message):
            model.isRepairing = false
            model.repairError = message
        }
    }

    // MARK: Rows

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
