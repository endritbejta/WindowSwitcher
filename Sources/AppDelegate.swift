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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Rebuild the menu labels whenever the shortcut changes.
        AppSettings.shared.onChange = { [weak self] in
            self?.updateStatusMenu(running: self?.isRunning ?? false)
        }
        setupStatusItem()

        // Only Accessibility is required to run; Screen Recording is optional
        // (previews fall back to app icons without it). Start whenever we can,
        // and still surface onboarding if anything is missing so the user has a
        // path to grant it.
        if PermissionsManager.hasAccessibility() {
            startSwitcher()
        } else {
            // `prompt: true` is what actually gets the app *listed* in
            // Privacy & Security → Accessibility and shows the system's own
            // "would like to control this computer" alert — a silent check
            // (prompt: false) never registers the app there at all, so
            // without this call there could be nothing for the user to
            // toggle on no matter how many times they open Settings.
            _ = PermissionsManager.hasAccessibility(prompt: true)
        }
        if !PermissionsManager.allGranted {
            showOnboarding()
        }
    }

    // MARK: Setup

    /// Idempotent: installs the event tap once Accessibility is granted.
    private func startSwitcher() {
        guard !isRunning else { return }
        if switcher.start() {
            isRunning = true
            updateStatusMenu(running: true)
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
                    self?.startSwitcher()
                },
                onRestart: { [weak self] in self?.relaunch() }
            )
        }
        onboarding?.present()
    }

    /// Relaunch the app in a fresh process. macOS applies a freshly-granted
    /// permission to the new instance; the old one exits once the new one is up.
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
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

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.present()
    }

    @objc private func quit() {
        switcher.stop()
        NSApp.terminate(nil)
    }
}
