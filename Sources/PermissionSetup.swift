import AppKit
import os

private let log = Logger(subsystem: "com.example.windowswitcher", category: "setup")

/// Works out *why* the app is not able to run, and performs the repairs.
///
/// The plain "open System Settings and toggle it on" advice only works when the
/// app has a stable code identity and lives somewhere macOS will not relocate
/// it. When it doesn't, toggling forever produces no effect — so before asking
/// the user to grant anything, figure out whether granting can even stick, and
/// offer the fix that makes it stick.
enum PermissionSetup {

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.example.windowswitcher"
    }

    /// Something standing between the user and a permission grant that lasts.
    enum Blocker: Hashable {

        /// macOS is running a disposable copy from a randomised path. A grant
        /// given now is discarded at quit. Nothing works until the app is moved.
        case translocated

        /// macOS holds a grant for a *previous* code identity of this app. The
        /// toggle in System Settings looks enabled but applies to something the
        /// system considers a different app, so the stale entry has to be
        /// cleared before a new grant can take.
        case staleGrant

        /// The signature is ad-hoc or missing, so the grant is pinned to the
        /// binary hash and will be lost by the next rebuild. The app still runs
        /// once granted — this is a warning about the next update, not a block.
        case unstableIdentity

        /// Running from Downloads/Desktop. Works, but the app is one
        /// re-download away from being quarantined and translocated again.
        case notInstalled

        /// Highest-priority blockers first.
        var priority: Int {
            switch self {
            case .translocated: return 0
            case .staleGrant: return 1
            case .unstableIdentity: return 2
            case .notInstalled: return 3
            }
        }

        /// True when the app genuinely cannot be granted permission until this
        /// is dealt with, as opposed to merely being fragile.
        var isFatal: Bool { self == .translocated || self == .staleGrant }

        var title: String {
            switch self {
            case .translocated: return "Move Window Switcher to Applications"
            case .staleGrant: return "Clear the stale permission entry"
            case .unstableIdentity: return "This build has an unstable identity"
            case .notInstalled: return "Install to Applications"
            }
        }

        var detail: String {
            switch self {
            case .translocated:
                return """
                macOS is running this copy from a temporary, randomly-named folder because it was \
                downloaded — so any permission you grant is thrown away when you quit. Move it to \
                Applications and the grant will stick.
                """
            case .staleGrant:
                return """
                macOS still has a permission entry for an earlier version of this app. The toggle \
                looks enabled, but it applies to the old identity, so this copy is never seen as \
                trusted. Clearing the entry lets you grant it once more, for good.
                """
            case .unstableIdentity:
                return """
                This copy is ad-hoc signed, so macOS pins the permission to this exact binary and \
                forgets it on the next rebuild. Run ./setup-signing.sh once, then rebuild, and \
                grants will persist across every future update.
                """
            case .notInstalled:
                return """
                The app is running from outside your Applications folder. It works, but moving it \
                to Applications protects the permission from being lost if the app is ever \
                re-downloaded or moved.
                """
            }
        }

        /// Label for the button that fixes it, when it can be fixed in-app.
        var actionTitle: String? {
            switch self {
            case .translocated, .notInstalled: return "Move to Applications"
            case .staleGrant: return "Reset & Re-grant"
            case .unstableIdentity: return nil
            }
        }
    }

    /// Everything currently wrong, worst first.
    static func blockers() -> [Blocker] {
        var found: [Blocker] = []

        if AppIdentity.isTranslocated {
            found.append(.translocated)
        }

        // A changed identity means macOS's existing entry is for a different
        // app as far as TCC is concerned. Only report it while we are in fact
        // untrusted — if the grant already applies, there is nothing to fix.
        if AppIdentity.identityChangedSinceLastLaunch, !PermissionsManager.hasAccessibility() {
            found.append(.staleGrant)
        }

        if !AppIdentity.signing.grantsSurviveRebuild {
            found.append(.unstableIdentity)
        }

        if !AppIdentity.isInApplicationsFolder && !AppIdentity.isTranslocated {
            found.append(.notInstalled)
        }

        return found.sorted { $0.priority < $1.priority }
    }

    // MARK: Repairs

    enum RepairResult {
        case relaunching
        case failed(String)
    }

    /// Copy the app into /Applications, strip the download quarantine, and
    /// relaunch from there. This is the fix for a translocated or quarantined
    /// copy: the new location is stable, so the permission grant survives.
    static func installToApplications(completion: @escaping (RepairResult) -> Void) {
        let source = AppIdentity.bundleURL
        let manager = FileManager.default

        // Prefer /Applications; fall back to ~/Applications when it isn't
        // writable (a managed Mac, or a non-admin account).
        var candidates = [URL(fileURLWithPath: "/Applications")]
        candidates.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"))

        for directory in candidates {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            do {
                if !manager.fileExists(atPath: directory.path) {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                // Replacing a previous install: remove it first. `source` is
                // never the destination here — callers only reach this when the
                // app is running from somewhere else.
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.copyItem(at: source, to: destination)
                stripQuarantine(at: destination)
                log.notice("installed to \(destination.path, privacy: .public)")
                relaunch(from: destination)
                completion(.relaunching)
                return
            } catch {
                log.error("install to \(directory.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        // Both locations refused the copy — hand the user the bundle so they can
        // drag it across themselves.
        NSWorkspace.shared.activateFileViewerSelecting([source])
        completion(.failed("Couldn't copy the app automatically. Drag Window Switcher into your Applications folder, then open it from there."))
    }

    /// Ask macOS to forget its permission entries for this bundle identifier,
    /// then relaunch so the app can request them again from a clean slate. This
    /// is what breaks the "the toggle is on but the app says it isn't" deadlock.
    static func resetGrantsAndRelaunch(completion: @escaping (RepairResult) -> Void) {
        let services = ["Accessibility", "ScreenCapture"]
        var reset = false
        for service in services where runTCCUtilReset(service: service) {
            reset = true
        }

        guard reset else {
            // `tccutil` refused. The manual equivalent is to select the app in
            // the Accessibility list and click the "–" button, so send the user
            // straight there.
            PermissionsManager.openAccessibilitySettings()
            completion(.failed("Couldn't reset it automatically. In the Accessibility list that just opened, select Window Switcher, click the “–” button to remove it, then add it back with “+”."))
            return
        }

        // The entry is gone, so the next launch is treated as a first run and
        // the system prompt appears again.
        UserDefaults.standard.removeObject(forKey: "lastSeenDesignatedRequirement")
        relaunch(from: AppIdentity.bundleURL)
        completion(.relaunching)
    }

    /// Launch a fresh instance at `url` and exit this one. A newly-granted
    /// permission is only picked up by a new process, so every repair ends here.
    static func relaunch(from url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                log.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Shell-outs

    @discardableResult
    private static func runTCCUtilReset(service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            log.notice("tccutil reset \(service, privacy: .public) -> \(ok)")
            return ok
        } catch {
            log.error("tccutil failed to run: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Remove the download flag from the installed copy, so macOS stops
    /// translocating it and Gatekeeper stops re-prompting.
    private static func stripQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
