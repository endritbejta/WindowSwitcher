import Foundation

/// The app's identifiers, kept in one place.
///
/// The bundle id is part of the code-signing designated requirement, and
/// macOS ties privacy grants to that requirement. So the id is not a cosmetic
/// name. Changing it once, from the `com.example` placeholder, means every
/// install grants Accessibility again. `PermissionSetup` and `reinstall.sh`
/// clear the grants left under the old id.
enum AppBundle {
    /// Must match `CFBundleIdentifier` in Info.plist and `BUNDLE_ID` in the
    /// build scripts.
    static let identifier = "com.endritbejta.windowswitcher"

    /// The placeholder id used by every build before the rename. Kept so that
    /// settings can be migrated from it and its stale grants cleared.
    static let legacyIdentifier = "com.example.windowswitcher"

    /// The unified-log subsystem for every `Logger` in the app.
    static let logSubsystem = identifier
}

/// Brings settings across from the pre-rename defaults domain, once.
///
/// It copies every key the old domain has that the new one doesn't: the
/// shortcut and ordering preferences, the diagnostics flag, and the last-seen
/// designated requirement. Copying that last one makes `AppIdentity` notice on
/// the first launch under the new id that the code identity changed, so it
/// offers **Reset Permissions & Restart** instead of a toggle that can't help.
///
/// It must run before anything reads `AppSettings.shared` or `AppIdentity`,
/// which is why `main.swift` calls it first. The old domain is left in place.
enum LegacyDefaultsMigration {

    static let completedKey = "migratedFromLegacyBundleID"

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        // Reading another domain this way works because the app isn't
        // sandboxed. It is nil when the old version never ran on this Mac.
        let legacy = defaults.persistentDomain(forName: AppBundle.legacyIdentifier)
        let plan = plan(
            alreadyDone: defaults.bool(forKey: completedKey),
            legacy: legacy,
            hasValue: { defaults.object(forKey: $0) != nil }
        )
        guard plan.markDone else { return }
        for (key, value) in plan.copy { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: completedKey)
        if !plan.copy.isEmpty {
            NSLog("WindowSwitcher: migrated %ld setting(s) from %@: %@",
                  plan.copy.count, AppBundle.legacyIdentifier, plan.copy.keys.sorted().joined(separator: ", "))
        }
    }

    struct Plan {
        /// The legacy values to write into the current domain.
        var copy: [String: Any]
        /// False only when the migration already ran, in which case nothing
        /// is written at all.
        var markDone: Bool
    }

    /// The decision, without touching any preferences, so it can be
    /// unit-tested. A key is copied only if the current domain has no value
    /// for it. Settings already made under the new id always win.
    static func plan(alreadyDone: Bool, legacy: [String: Any]?, hasValue: (String) -> Bool) -> Plan {
        guard !alreadyDone else { return Plan(copy: [:], markDone: false) }
        let copy = (legacy ?? [:]).filter { key, _ in key != completedKey && !hasValue(key) }
        return Plan(copy: copy, markDone: true)
    }
}
