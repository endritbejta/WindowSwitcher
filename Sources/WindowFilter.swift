import CoreGraphics

/// Drops on-screen windows that the window server lists but the owning app
/// doesn't consider windows of its own.
///
/// The case that motivated it is a full-screen app. On its full-screen Space,
/// macOS draws the title bar and toolbar in a separate layer-0 window across the
/// top of the screen. To CoreGraphics that is just another normal window of the
/// app, so Calendar or Chrome showed up twice, the second time with an empty
/// preview. The app's Accessibility window list doesn't include it, and that list
/// is what the user thinks of as the app's windows.
///
/// This is kept free of AppKit and Accessibility so it can be unit-tested; the
/// caller supplies the Accessibility answer.
enum WindowFilter {

    /// The ids from `candidates` that should be listed.
    ///
    /// - `candidates`: on-screen windows that passed the CoreGraphics checks.
    /// - `accessibleWindows`: the window ids an app reports through
    ///   Accessibility, or nil if it couldn't be asked. Only called for apps
    ///   with more than one candidate: with a single window there is nothing to
    ///   tell apart, and it saves a round trip to every other app.
    ///
    /// The filter never hides an app's windows because of a missing answer. If
    /// the app can't be asked, reports no windows, or reports none of the
    /// candidates (for example, the id helper is unavailable), all of that app's
    /// candidates are kept.
    static func listed(
        _ candidates: [(id: CGWindowID, pid: pid_t)],
        accessibleWindows: (pid_t) -> Set<CGWindowID>?
    ) -> Set<CGWindowID> {
        var byPID: [pid_t: [CGWindowID]] = [:]
        for candidate in candidates { byPID[candidate.pid, default: []].append(candidate.id) }

        var keep = Set<CGWindowID>()
        for (pid, ids) in byPID {
            guard ids.count > 1, let reported = accessibleWindows(pid) else {
                keep.formUnion(ids)
                continue
            }
            let confirmed = ids.filter { reported.contains($0) }
            keep.formUnion(confirmed.isEmpty ? ids : confirmed)
        }
        return keep
    }
}
