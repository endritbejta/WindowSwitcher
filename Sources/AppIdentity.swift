import AppKit
import Darwin
import Security
import os

private let log = Logger(subsystem: "com.example.windowswitcher", category: "identity")

/// Facts about *this* running copy of the app: how it is code-signed and where
/// it lives on disk.
///
/// Both matter because macOS TCC (the database behind Privacy & Security) does
/// not remember "WindowSwitcher" by name. It stores a grant against the app's
/// **designated requirement** — a code-signing predicate. When that predicate
/// changes, the grant you already gave belongs to something macOS considers a
/// different app: the toggle still reads as ON in System Settings, but
/// `AXIsProcessTrusted()` returns false forever. That is the "I gave it
/// permission and it doesn't recognise it" loop, and it has exactly three
/// causes, all detected here:
///
///   1. Ad-hoc signing (`codesign --sign -`) produces a requirement pinned to
///      the binary's cdhash, so *every rebuild* orphans the grant.
///   2. A self-signed certificate that was generated separately on each machine
///      pins a different certificate hash per machine, so a grant given on one
///      Mac means nothing on the next.
///   3. App Translocation: a downloaded, non-notarised app is run from a
///      randomised read-only path under `/AppTranslocation/`, which is thrown
///      away and regenerated, so the grant cannot outlive the launch.
enum AppIdentity {

    /// How this copy is signed — i.e. what the grant is pinned to.
    enum Signing {
        /// Apple-issued Developer ID. Pinned to the team identifier: stable
        /// across rebuilds and machines. The best case.
        case developerID(team: String)
        /// A self-signed certificate. Pinned to that certificate's hash, so it
        /// is stable for as long as the *same* certificate is used — which
        /// means the certificate has to be shared between machines, not
        /// regenerated on each one.
        case pinnedCertificate(leaf: String)
        /// Ad-hoc: pinned to the binary hash. Grants cannot survive a rebuild.
        case adHoc
        case unsigned

        /// Can a permission grant given to this copy outlive a rebuild?
        var grantsSurviveRebuild: Bool {
            switch self {
            case .developerID, .pinnedCertificate: return true
            case .adHoc, .unsigned: return false
            }
        }

        var shortDescription: String {
            switch self {
            case .developerID(let team): return "Developer ID (team \(team))"
            case .pinnedCertificate(let leaf): return "self-signed certificate \(leaf.prefix(8))…"
            case .adHoc: return "ad-hoc (unstable)"
            case .unsigned: return "unsigned"
            }
        }
    }

    /// The bundle this process is running out of.
    static var bundleURL: URL { Bundle.main.bundleURL }

    /// The designated requirement string, i.e. the exact predicate TCC keys the
    /// grant against. This is the identity that has to stay constant.
    static let designatedRequirement: String? = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess,
              let text else { return nil }
        return text as String
    }()

    /// Classify the signature by reading the designated requirement, which
    /// spells out what the grant is pinned to.
    static let signing: Signing = {
        guard let requirement = designatedRequirement else { return .unsigned }
        // Developer ID: "anchor apple generic and ... certificate leaf[subject.OU] = TEAMID"
        if requirement.contains("anchor apple generic"),
           let team = capture(in: requirement, after: "subject.OU] = ") {
            return .developerID(team: team)
        }
        // Self-signed: "... and certificate leaf = H\"<sha1>\""
        if let leaf = capture(in: requirement, after: "certificate leaf = H\"") {
            return .pinnedCertificate(leaf: leaf)
        }
        // Ad-hoc leaves nothing to pin to but the binary hash itself.
        if requirement.contains("cdhash") { return .adHoc }
        return .unsigned
    }()

    /// True when macOS is running us from a randomised App Translocation path.
    /// This happens to a downloaded app that is not notarised, and it makes a
    /// permission grant impossible to keep: the path is disposable.
    static var isTranslocated: Bool {
        bundleURL.path.contains("/AppTranslocation/")
    }

    /// True when the bundle still carries the download quarantine flag. Left in
    /// place, this is what triggers translocation on the next launch even if the
    /// current launch happens to be running from the real path.
    static var isQuarantined: Bool {
        bundleURL.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    /// `/Applications` (or `~/Applications`) is the only location where macOS
    /// will never translocate the app and never quarantine it again.
    static var isInApplicationsFolder: Bool {
        let path = bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Where `installToApplications()` would put the app.
    static var preferredInstallURL: URL {
        URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleURL.lastPathComponent)
    }

    // MARK: Identity change detection

    private static let storedRequirementKey = "lastSeenDesignatedRequirement"

    /// The designated requirement this app had the last time it ran on this Mac.
    static var previousDesignatedRequirement: String? {
        UserDefaults.standard.string(forKey: storedRequirementKey)
    }

    /// True when the code identity changed since the last launch — meaning any
    /// permission macOS has on file was granted to the *previous* identity and
    /// is now dead. This is the one case where "just grant it again" does not
    /// work: the stale entry has to be cleared first.
    static var identityChangedSinceLastLaunch: Bool {
        guard let previous = previousDesignatedRequirement,
              let current = designatedRequirement else { return false }
        return previous != current
    }

    /// Record the current identity as the known-good one. Called once the app
    /// is actually running with the permissions it needs, so that a later
    /// change is detectable.
    static func rememberCurrentIdentity() {
        guard let current = designatedRequirement else { return }
        UserDefaults.standard.set(current, forKey: storedRequirementKey)
    }

    // MARK: Helpers

    /// Pull the token that follows `marker`, stripping a trailing quote. Used to
    /// lift the team identifier / certificate hash out of the requirement text.
    private static func capture(in text: String, after marker: String) -> String? {
        guard let start = text.range(of: marker) else { return nil }
        let rest = text[start.upperBound...]
        let token = rest.prefix { $0 != "\"" && !$0.isWhitespace }
        return token.isEmpty ? nil : String(token)
    }

    /// One-line summary for the log and the diagnostics view.
    static func describe() -> String {
        """
        bundle: \(bundleURL.path)
        signing: \(signing.shortDescription)
        requirement: \(designatedRequirement ?? "none")
        translocated: \(isTranslocated), quarantined: \(isQuarantined), \
        inApplications: \(isInApplicationsFolder)
        """
    }

    static func logState() {
        log.notice("\(describe(), privacy: .public)")
    }
}
