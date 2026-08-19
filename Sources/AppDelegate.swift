import AppKit

/// Application lifecycle: sets up the menu-bar item, ensures permissions, and
/// starts the switcher once everything is granted.
///
/// The app runs as an "accessory" (no Dock icon, no menu bar of its own) — it
/// is a background utility, exactly like the system's own switcher.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let switcher = SwitcherController()
    private var statusItem: NSStatusItem?
    private var onboarding: OnboardingWindowController?
    private var settingsWindow: SettingsWindowController?
    private var isRunning = false
    /// Retries tap installation after the app launches without permission but
    /// gains it later (granted in System Settings while we sit in the menu bar
    /// with the setup window closed).
    private var permissionWatchdog: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Record how this copy is signed and where it is running from. When a
        // permission stops being recognised, this line in Console is the
        // difference between diagnosing it and guessing.
        AppIdentity.logState()
        // Compare this launch's code identity against the previous one before
        // anything else reads it — a change means macOS's existing grant belongs
        // to an identity that no longer exists.
        AppIdentity.beginSession()

        // Rebuild the menu labels whenever the shortcut changes.
        AppSettings.shared.onChange = { [weak self] in
            self?.updateStatusMenu(running: self?.isRunning ?? false)
        }
        setupStatusItem()

        // A translocated copy is running from a disposable path, so no grant
        // given now can survive. Go straight to setup, which offers the move to
        // /Applications that fixes it — asking for permission first would just
        // waste the user's time.
        let fatalBlocker = PermissionSetup.blockers().contains { $0.isFatal }

        // Only Accessibility is required to run; Screen Recording is optional
        // (previews fall back to app icons without it). Start whenever we can,
        // and still surface onboarding if anything is missing so the user has a
        // path to grant it.
        if !fatalBlocker && PermissionsManager.hasAccessibility() {
            startSwitcher()
        } else if !fatalBlocker {
            // `prompt: true` is what actually gets the app *listed* in
            // Privacy & Security → Accessibility and shows the system's own
            // "would like to control this computer" alert — a silent check
            // (prompt: false) never registers the app there at all, so
            // without this call there could be nothing for the user to
            // toggle on no matter how many times they open Settings.
            _ = PermissionsManager.hasAccessibility(prompt: true)
        }

        // Open setup only when something actually needs the user: a blocker, or
        // the required permission missing. Screen Recording is optional, so a
        // switcher that is already running must not reopen this window on every
        // launch — that nagging is what makes a working app feel broken.
        if fatalBlocker || !isRunning {
            showOnboarding()
        }
        startPermissionWatchdog()
    }

    // MARK: Setup

    /// Idempotent: installs the event tap once Accessibility is granted, and
    /// reports whether the tap is now live. Returns false while the permission
    /// is missing or tap creation fails, so callers can retry — a grant that has
    /// only just landed sometimes needs a moment before `CGEvent.tapCreate`
    /// succeeds.
    @discardableResult
    private func startSwitcher() -> Bool {
        guard !isRunning else { return true }
        guard switcher.start() else { return false }
        isRunning = true
        updateStatusMenu(running: true)
        return true
    }

    /// Keep checking in the background so a permission granted while the setup
    /// window is closed still brings the switcher up, without the user having to
    /// restart the app or reopen the window.
    private func startPermissionWatchdog() {
        guard !isRunning else { return }
        permissionWatchdog?.invalidate()
        permissionWatchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.isRunning {
                timer.invalidate()
                self.permissionWatchdog = nil
                return
            }
            guard !PermissionSetup.blockers().contains(where: { $0.isFatal }) else { return }
            if PermissionsManager.hasAccessibility() {
                self.startSwitcher()
            }
        }
    }

    private func showOnboarding() {
        updateStatusMenu(running: isRunning)
        // Reuse an existing window if it's already up.
        if onboarding == nil {
            onboarding = OnboardingWindowController(
                onAccessibilityReady: { [weak self] in
                    // Start the switcher as soon as Accessibility lands; leave
                    // the window open so the user can still enable previews.
                    // The returned flag tells the window whether the tap is
                    // really live, so it keeps retrying if it is not.
                    self?.startSwitcher() ?? false
                },
                onRestart: { [weak self] in self?.relaunch() }
            )
        }
        onboarding?.present()
    }

    /// Relaunch the app in a fresh process. macOS applies a freshly-granted
    /// permission to the new instance; the old one exits once the new one is up.
    private func relaunch() {
        PermissionSetup.relaunch(from: Bundle.main.bundleURL)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = AppIcon.makeStatusItemImage()
        }
        statusItem = item
        updateStatusMenu(running: false)
    }

    private func updateStatusMenu(running: Bool) {
        let menu = NSMenu()
        let status = NSMenuItem(
            title: running
                ? "Window Switcher — Active (\(AppSettings.shared.shortcutDisplay))"
                : "Window Switcher — Needs Permissions",
            action: nil, keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if !running {
            menu.addItem(NSMenuItem(title: "Grant Permissions…",
                                    action: #selector(openOnboarding),
                                    keyEquivalent: ""))
            // The escape hatch for "the toggle is on but the app disagrees".
            // Reachable here as well as in the setup window, because a user who
            // granted the permission in System Settings has no reason to think
            // the answer lives behind a setup screen.
            menu.addItem(NSMenuItem(title: "Reset Permissions & Restart",
                                    action: #selector(resetPermissions),
                                    keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "Settings…",
                                action: #selector(openSettings),
                                keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(quit),
                                keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem?.menu = menu
    }

    // MARK: Actions

    @objc private func openOnboarding() { showOnboarding() }

    @objc private func resetPermissions() {
        PermissionSetup.resetGrantsAndRelaunch { [weak self] result in
            DispatchQueue.main.async {
                // A failed reset falls back to the setup window, which explains
                // the manual route (remove the entry with "–", then re-add).
                if case .failed = result { self?.showOnboarding() }
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.present()
    }

    @objc private func quit() {
        switcher.stop()
        NSApp.terminate(nil)
    }
}
