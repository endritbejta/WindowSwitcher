import AppKit
import os

/// Diagnostics for recently-used ordering — off by default.
///
/// Turn on with
///
///     defaults write com.example.windowswitcher debug.mruLogging -bool YES
///
/// and watch with
///
///     log stream --predicate 'subsystem == "com.example.windowswitcher" AND category == "mru"' --level info
///
/// The flag is read live, so neither step needs a relaunch. While it is off,
/// every entry point returns before computing anything — in particular the
/// extra Accessibility queries made here never run, so switching behaves
/// exactly as it does without this file.
///
/// Lines that indicate history and reality disagreeing are logged at error
/// level with an `ANOMALY <kind>` prefix, so a session can be triaged with
/// `grep ANOMALY`. Each line starts with a monotonic timestamp in
/// milliseconds, so the gap between events (e.g. two quick taps) can be read
/// straight off the log.
enum MRULog {

    private static let log = Logger(subsystem: "com.example.windowswitcher", category: "mru")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "debug.mruLogging") }

    /// Milliseconds since boot. Monotonic, unlike wall-clock time.
    static var nowMs: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    static func info(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        let stamp = String(format: "%.1f", nowMs)
        log.info("[\(stamp, privacy: .public)] \(text, privacy: .public)")
    }

    static func anomaly(_ kind: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        let stamp = String(format: "%.1f", nowMs)
        log.error("[\(stamp, privacy: .public)] ANOMALY \(kind, privacy: .public): \(text, privacy: .public)")
    }

    // MARK: Readable window ids

    /// Window id → app name, learned from each enumeration so later lines
    /// (which only carry ids) stay readable. Bounded by the windows that were
    /// on screen at the last open.
    private static var names: [CGWindowID: String] = [:]

    static func remember(_ windows: [WindowInfo]) {
        guard isEnabled else { return }
        names = Dictionary(windows.map { ($0.id, $0.appName) }, uniquingKeysWith: { first, _ in first })
    }

    static func describe(_ id: CGWindowID?) -> String {
        guard let id else { return "nil" }
        return names[id].map { "\(id)(\($0))" } ?? "\(id)"
    }

    static func describe(_ ids: [CGWindowID], limit: Int = 6) -> String {
        let shown = ids.prefix(limit).map { describe($0) }.joined(separator: ", ")
        return ids.count > limit ? "[\(shown), …+\(ids.count - limit)]" : "[\(shown)]"
    }

    // MARK: Ground truth

    /// What actually has keyboard focus right now: the frontmost application
    /// and, via Accessibility, its focused window. This is the reference the
    /// switcher's own state is checked against. Only called while logging is
    /// enabled, since it costs an Accessibility round trip.
    static func actualFocus() -> (pid: pid_t, app: String, windowID: CGWindowID?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        return (pid, app.localizedName ?? "?", WindowActivator.focusedWindowID(forPID: pid))
    }
}
