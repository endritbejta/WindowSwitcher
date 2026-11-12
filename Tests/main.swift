// Unit tests for the window-ordering rules (Sources/WindowHistory.swift) and
// the gesture state machine (Sources/GestureTracker.swift).
//
// Run with `./build.sh test`. That compiles this file together with
// those two files only. No AppKit, no permissions and no running apps are
// needed, so the tests are fast and deterministic.

import CoreGraphics
import Foundation

// MARK: - Minimal harness

var failures = 0
var checks = 0
var currentTest = ""

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
           file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  ✘ \(currentTest) (line \(line)) \(message())")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ note: String = "", line: UInt = #line) {
    check(actual == expected, "expected \(expected), got \(actual) \(note)", line: line)
}

func test(_ name: String, _ body: () -> Void) {
    currentTest = name
    let before = failures
    body()
    print(failures == before ? "  ✔ \(name)" : "  ✘ \(name) — FAILED")
}

// MARK: - A model of the system, driven through the real rules
//
// `Driver` scripts the macOS side: z-order, the frontmost app, what
// Accessibility reports, and when notifications arrive. It hands each event
// to the same `WindowOrderState` methods `WindowOrderManager` calls, and uses
// `WindowFocus.systemFocused`, the same "current" fallback. So the scenarios
// below test the shipping ordering logic, not a copy of it. The only thing
// the Driver adds is the selection step from `SwitcherController.open()`.

struct Win { let id: CGWindowID; let pid: pid_t; var onScreen = true }

struct Driver {
    var state: WindowOrderState
    var now: Double = 100
    var recentlyUsed = true

    let ownPID: pid_t = 999
    var windows: [Win]               // front-to-back z-order; only on-screen ones are visible
    var closed = Set<CGWindowID>()   // ids no longer existing
    var frontmostPID: pid_t?         // NSWorkspace.frontmostApplication
    var axFocused: [pid_t: CGWindowID] = [:]   // what Accessibility reports per app
    var axQueries = 0

    var history: WindowHistory { state.history }
    var pending: PendingCommit? { state.pending }

    init(_ windows: [Win], focused: CGWindowID) {
        self.windows = windows
        let w = windows.first { $0.id == focused }!
        frontmostPID = w.pid
        for win in windows.reversed() { axFocused[win.pid] = win.id }  // front-most window per app
        axFocused[w.pid] = focused
        // Seed like `WindowOrderManager.start()`: the current z-order.
        state = WindowOrderState(seed: windows.map(\.id))
    }

    var visible: [Win] { windows.filter { $0.onScreen && !closed.contains($0.id) } }
    func pid(of id: CGWindowID) -> pid_t { windows.first { $0.id == id }!.pid }

    /// The settled, user-visible truth: what really has focus.
    var trulyFocused: CGWindowID? { frontmostPID.flatMap { axFocused[$0] } }

    /// `orderedWindows()`, then the selection in `SwitcherController.open()`.
    mutating func open(reverse: Bool = false) -> (list: [CGWindowID], selected: CGWindowID, current: CGWindowID?) {
        let vis = visible
        let front = frontmostPID, own = ownPID, ax = axFocused
        var queries = 0
        let opened = state.open(
            visible: vis.map(\.id),
            existing: Set(windows.map(\.id)).subtracting(closed),
            frontmostAppFront: front.flatMap { pid in vis.first { $0.pid == pid }?.id },
            recentlyUsed: recentlyUsed,
            now: now
        ) {
            WindowFocus.systemFocused(
                frontmostPID: front, ownPID: own,
                visible: vis.map { (id: $0.id, pid: $0.pid) },
                axFocused: { queries += 1; return ax[$0] }
            )
        }
        axQueries += queries
        let index = WindowHistory.initialSelection(
            count: opened.ordered.count,
            anchor: opened.current.flatMap { opened.ordered.firstIndex(of: $0) },
            reverse: reverse
        )
        return (opened.ordered, opened.ordered[index], opened.current)
    }

    /// `noteCommit`, with the frontmost app as macOS reports it at that moment.
    mutating func commit(_ id: CGWindowID) {
        state.commit(pid: pid(of: id), windowID: id, frontmostPID: frontmostPID,
                     recentlyUsed: recentlyUsed, now: now)
    }

    /// An NSWorkspace didActivateApplication notification for `pid`, handled now.
    mutating func activation(_ pid: pid_t) {
        let ax = axFocused
        var queried = false
        state.activation(notifiedPID: pid, ownPID: ownPID, recentlyUsed: recentlyUsed, now: now) {
            queried = true; return ax[pid]
        }
        if queried { axQueries += 1 }
    }

    /// An AX focused-window-changed event from the observed app.
    mutating func focusChanged(_ pid: pid_t, to id: CGWindowID) {
        state.focusChanged(pid: pid, windowID: id, recentlyUsed: recentlyUsed, now: now)
    }

    /// The user moves focus to another window of the frontmost app, for
    /// example with ⌘`. No workspace notification fires, only the AX event.
    mutating func inAppFocus(_ id: CGWindowID) {
        now += 0.05
        let p = pid(of: id)
        axFocused[p] = id
        focusChanged(p, to: id)
        now += 0.3
    }

    /// The system finishes carrying out a switch to `id`. Activation is
    /// posted only when the app changes; same-app switches post an AX focus
    /// event instead.
    ///
    /// The window is raised to the front of the z-order. With
    /// `focusFollows: false` the app behaves like Calendar: it raises the
    /// window but keeps reporting (and posting) its previous window as
    /// focused.
    mutating func systemSettles(on id: CGWindowID, notify: Bool = true, focusFollows: Bool = true) {
        let p = pid(of: id)
        let changedApp = frontmostPID != p
        frontmostPID = p
        if let i = windows.firstIndex(where: { $0.id == id }) { windows.insert(windows.remove(at: i), at: 0) }
        if focusFollows { axFocused[p] = id }
        guard notify else { return }
        if changedApp { activation(p) } else if focusFollows { focusChanged(p, to: id) }
    }

    /// A quick tap (press and release) that is allowed to settle before the
    /// next one.
    @discardableResult
    mutating func settledTap(reverse: Bool = false) -> CGWindowID {
        let s = open(reverse: reverse).selected
        commit(s)
        now += 0.05
        systemSettles(on: s)
        now += 0.3
        return s
    }

    /// The user focuses `id` outside the switcher, for example with a click
    /// or the Dock.
    mutating func externalFocus(_ id: CGWindowID) {
        now += 0.05
        systemSettles(on: id)
        now += 0.3
    }
}

// Window ids: A=1 (pid 10), B=2 (pid 20), C=3 (pid 30)
let A: CGWindowID = 1, B: CGWindowID = 2, C: CGWindowID = 3
func threeApps() -> Driver {
    Driver([Win(id: A, pid: 10), Win(id: B, pid: 20), Win(id: C, pid: 30)], focused: A)
}

print("WindowHistory tests")

// MARK: - WindowHistory primitives

test("promote moves to the front and inserts new ids") {
    var h = WindowHistory(order: [1, 2, 3])
    h.promote(3); equal(h.order, [3, 1, 2])
    h.promote(9); equal(h.order, [9, 3, 1, 2])
}

test("promoting the head twice (duplicate event) changes nothing") {
    var h = WindowHistory(order: [1, 2, 3])
    h.promote(1); h.promote(1); equal(h.order, [1, 2, 3])
}

test("init drops duplicate ids") {
    equal(WindowHistory(order: [1, 2, 1, 3, 2]).order, [1, 2, 3])
}

test("reconcile drops only windows that no longer exist") {
    var h = WindowHistory(order: [1, 2, 3, 4])
    h.reconcile(existing: [1, 3, 4])
    equal(h.order, [1, 3, 4])
}

test("arrange keeps history order for visible ids and appends new ones in z-order") {
    var h = WindowHistory(order: [3, 1, 2])
    equal(h.arrange(visible: [5, 1, 3, 4]), [3, 1, 5, 4])   // 2 not visible
    equal(h.order, [3, 1, 2, 5, 4])                          // 2 keeps its slot; new ones recorded
}

test("arrange tolerates duplicate visible ids") {
    var h = WindowHistory()
    equal(h.arrange(visible: [1, 1, 2]), [1, 2])
}

test("prepareOpen with unreadable window list forgets nothing") {
    var h = WindowHistory(order: [1, 2, 3])
    _ = h.prepareOpen(visible: [1], existing: nil, current: 1, recentlyUsed: true)
    equal(h.order, [1, 2, 3])
}

test("prepareOpen never forgets a visible window even if 'existing' misses it") {
    var h = WindowHistory(order: [1, 2])
    _ = h.prepareOpen(visible: [1, 2], existing: [], current: nil, recentlyUsed: true)
    equal(h.order, [1, 2])
}

test("initialSelection: next/previous of anchor, with wrap") {
    equal(WindowHistory.initialSelection(count: 3, anchor: 0, reverse: false), 1)
    equal(WindowHistory.initialSelection(count: 3, anchor: 0, reverse: true), 2)
    equal(WindowHistory.initialSelection(count: 3, anchor: 2, reverse: false), 0)
}

test("initialSelection: absent anchor starts at the end the gesture heads towards") {
    equal(WindowHistory.initialSelection(count: 4, anchor: nil, reverse: false), 0)
    equal(WindowHistory.initialSelection(count: 4, anchor: nil, reverse: true), 3)
}

test("initialSelection: single window and empty list are safe") {
    equal(WindowHistory.initialSelection(count: 1, anchor: 0, reverse: false), 0)
    equal(WindowHistory.initialSelection(count: 0, anchor: nil, reverse: false), 0)
}

// MARK: - WindowFocus.current

test("a live pending commit beats the system and skips the AX query") {
    var asked = false
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    let (id, source) = WindowFocus.current(pending: p, now: 10.2, visible: [A, B]) { asked = true; return A }
    equal(id, B); equal(source, .pending); check(!asked, "system should not be queried")
}

test("an expired pending commit defers to the system") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(WindowFocus.current(pending: p, now: 10 + PendingCommit.lifetime + 0.01, visible: [A, B]) { A }.0, A)
}

test("a pending commit whose window vanished defers to the system") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(WindowFocus.current(pending: p, now: 10.1, visible: [A]) { A }.0, A)
}

test("a system-focused window that isn't listed gives no current window") {
    equal(WindowFocus.current(pending: nil, now: 0, visible: [A, B]) { 42 }.0, nil)
}

// MARK: - WindowFocus.onActivation

func activation(notified: pid_t, pending: PendingCommit? = nil,
                now: Double = 10.1, ax: CGWindowID? = 7, axCalled: UnsafeMutablePointer<Bool>? = nil) -> WindowFocus.Outcome {
    WindowFocus.onActivation(notifiedPID: notified, ownPID: 999,
                             pending: pending, now: now) { axCalled?.pointee = true; return ax }
}

test("own app's activation is ignored") {
    equal(activation(notified: 999).decision, .ignoreOwnApp)
}

test("with nothing settling, an activation is a real switch") {
    equal(activation(notified: 30, ax: C), .init(decision: .promote(C), clearPending: false))
}

test("while our cross-app commit settles, another app's activation predates it") {
    var called = false
    let p = PendingCommit(pid: 20, windowID: B, now: 10, expectsActivation: true)
    equal(activation(notified: 30, pending: p, ax: C, axCalled: &called),
          .init(decision: .ignoreStale, clearPending: false))
    check(!called, "a stale activation shouldn't cost an AX round trip")
}

test("the activation we asked for promotes the committed window, not AX's sibling") {
    var called = false
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    let o = activation(notified: 20, pending: p, ax: 77, axCalled: &called)
    equal(o, .init(decision: .promote(B), clearPending: true))
    check(!called, "AX should not be queried for our own commit")
}

test("after a same-app commit (no activation coming), another app's activation is real") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10, expectsActivation: false)
    equal(activation(notified: 30, pending: p, ax: C), .init(decision: .promote(C), clearPending: true))
}

test("an activation after the pending commit expired is treated as external") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(activation(notified: 30, pending: p, now: 12, ax: C), .init(decision: .promote(C), clearPending: true))
    equal(activation(notified: 20, pending: p, now: 12, ax: 77), .init(decision: .promote(77), clearPending: true))
}

test("an app with no AX focused window promotes nothing") {
    equal(activation(notified: 30, ax: nil).decision, .ignoreNoFocusedWindow)
}

test("own app's activation drops an expired pending commit but keeps a live one") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(activation(notified: 999, pending: p, now: 10.1).clearPending, false)
    equal(activation(notified: 999, pending: p, now: 12).clearPending, true)
}

// MARK: - WindowOrderState.commit: does an activation follow?

test("committing to another app expects its activation") {
    var s = WindowOrderState(seed: [A, B])
    s.commit(pid: 20, windowID: B, frontmostPID: 10, recentlyUsed: true, now: 0)
    equal(s.pending?.expectsActivation, true)
}

test("committing within the frontmost app expects no activation") {
    var s = WindowOrderState(seed: [A, B])
    s.commit(pid: 10, windowID: A, frontmostPID: 10, recentlyUsed: true, now: 0)
    equal(s.pending?.expectsActivation, false)
}

test("rapid second commit: the settling commit, not the lagging frontmost, decides") {
    var s = WindowOrderState(seed: [A, B])
    s.commit(pid: 20, windowID: B, frontmostPID: 10, recentlyUsed: true, now: 0)
    // macOS still reports A's app frontmost, but our switch to B is in flight,
    // so switching back to A *will* produce an activation.
    s.commit(pid: 10, windowID: A, frontmostPID: 10, recentlyUsed: true, now: 0.02)
    equal(s.pending?.expectsActivation, true)
}

// MARK: - WindowFocus.systemFocused

test("systemFocused: AX focused window if listed, else the app's front-most listed window") {
    let vis: [(id: CGWindowID, pid: pid_t)] = [(1, 10), (2, 20), (3, 20)]
    equal(WindowFocus.systemFocused(frontmostPID: 20, ownPID: 999, visible: vis) { _ in 3 }, 3)
    equal(WindowFocus.systemFocused(frontmostPID: 20, ownPID: 999, visible: vis) { _ in 42 }, 2, "unlisted panel → app's front window")
    equal(WindowFocus.systemFocused(frontmostPID: 20, ownPID: 999, visible: vis) { _ in nil }, 2, "no AX support → app's front window")
}

test("systemFocused: nil for our own app, unknown frontmost, or an app with nothing listed") {
    let vis: [(id: CGWindowID, pid: pid_t)] = [(1, 10)]
    var asked = false
    equal(WindowFocus.systemFocused(frontmostPID: 999, ownPID: 999, visible: vis) { _ in asked = true; return 1 }, nil)
    check(!asked, "no AX call for our own app")
    equal(WindowFocus.systemFocused(frontmostPID: nil, ownPID: 999, visible: vis) { _ in 1 }, nil)
    equal(WindowFocus.systemFocused(frontmostPID: 30, ownPID: 999, visible: vis) { _ in nil }, nil)
}

// MARK: - End-to-end scenarios (the reported bug and its variants)

test("baseline: a quick tap toggles between the two most recent windows") {
    var d = threeApps()
    equal(d.settledTap(), B)
    equal(d.settledTap(), A)
    equal(d.settledTap(), B)
    equal(d.history.order, [B, A, C])
}

test("BUG: rapid double tap before macOS settles returns to A, not C") {
    var d = threeApps()
    let first = d.open().selected; d.commit(first)
    d.now += 0.03                       // macOS hasn't activated B yet: frontmost/AX still say A
    let r = d.open()
    equal(first, B)
    equal(r.current, B, "the pending commit is current, not the stale system focus")
    equal(r.selected, A, "second tap must toggle back")
    d.commit(r.selected)
    equal(d.history.order, [A, B, C], "A must not drop to last")
    check(d.axQueries == 1, "only the very first open needed to ask the system, got \(d.axQueries)")
}

test("rapid taps with activations arriving late and out of order stay correct") {
    var d = threeApps()
    let t1 = d.open().selected; d.commit(t1)          // → B
    d.now += 0.02
    let t2 = d.open().selected; d.commit(t2)          // → A
    d.now += 0.02
    // macOS now delivers B's activation late; frontmost has already gone back to A.
    d.frontmostPID = 10
    d.activation(20)
    d.now += 0.02
    d.activation(10)
    equal([t1, t2], [B, A])
    equal(d.history.order, [A, B, C], "the stale notification for B must not reorder")
    d.now += 0.5
    equal(d.open().selected, B)
}

test("a late notification for an earlier switch can't put that window back in front") {
    var d = threeApps()
    d.settledTap()                       // A → B
    let s = d.open().selected; d.commit(s)  // → A
    d.frontmostPID = 10; d.axFocused[10] = A
    d.activation(20)                     // stale "B activated", delivered late
    equal(d.history.order.first, A)
}

test("multi-window app: AX reporting the sibling doesn't promote it") {
    // Terminal T (pid 10), Chrome C1/C2 (pid 20)
    let T: CGWindowID = 1, C1: CGWindowID = 2, C2: CGWindowID = 3
    var d = Driver([Win(id: T, pid: 10), Win(id: C1, pid: 20), Win(id: C2, pid: 20)], focused: T)
    // Hold and step twice to C2.
    let list = d.open().list
    equal(list, [T, C1, C2])
    d.commit(C2)
    d.now += 0.05
    d.frontmostPID = 20                 // Chrome active, but AX still says C1 is focused
    d.axFocused[20] = C1
    d.activation(20)
    equal(d.history.order, [C2, T, C1])
    // AX catches up; a quick tap must now return to T, then back to C2.
    d.axFocused[20] = C2
    d.now += 0.5
    equal(d.settledTap(), T)
    equal(d.settledTap(), C2)
}

test("switching windows inside one app (no activation event) is picked up at the next open") {
    let C1: CGWindowID = 2, C2: CGWindowID = 3
    // z-order front-to-back C1, A, C2, with Chrome's C1 focused: history [C1, A, C2].
    var d = Driver([Win(id: C1, pid: 20), Win(id: A, pid: 10), Win(id: C2, pid: 20)], focused: C1)
    d.axFocused[20] = C2                // user pressed ⌘` within Chrome: no NSWorkspace event
    let r = d.open()
    equal(r.current, C2)
    equal(r.list, [C2, C1, A])
    equal(r.selected, C1, "previous window is the one just left")
}

test("a window on another Space keeps its place in the history") {
    var d = threeApps()
    d.settledTap(); d.settledTap()          // order [A, B, C]
    d.windows[1].onScreen = false           // B is on another Space
    equal(d.open().list, [A, C])
    d.windows[1].onScreen = true            // back on B's Space
    equal(d.open().list, [A, B, C], "B returns to slot 2, not last")
}

test("hidden (⌘H) and minimised windows keep their place too") {
    var d = threeApps()
    d.externalFocus(C); d.externalFocus(B); d.externalFocus(A)   // [A, B, C]
    d.windows[1].onScreen = false
    _ = d.open(); _ = d.open()
    d.windows[1].onScreen = true
    equal(d.open().list, [A, B, C])
}

test("closed windows and quit apps are removed from the history") {
    var d = threeApps()
    d.closed.insert(B)
    equal(d.open().list, [A, C])
    equal(d.history.order, [A, C])
}

test("committing to a window that closed leaves the history consistent") {
    var d = threeApps()
    d.closed.insert(B)
    // (SwitcherController skips noteCommit for a vanished window.)
    let r = d.open()
    equal(r.list, [A, C])
    equal(r.selected, C)
}

test("the switcher's own Settings window activating doesn't reorder anything") {
    var d = threeApps()
    d.settledTap()                       // [B, A, C]
    d.frontmostPID = d.ownPID
    d.activation(d.ownPID)
    equal(d.history.order, [B, A, C])
    let r = d.open()                     // own window frontmost → no current window
    equal(r.current, nil)
    equal(r.selected, B, "forward tap lands on the most recent real window")
}

test("repeated activation of the same app is idempotent") {
    var d = threeApps()
    d.externalFocus(B)
    for _ in 0..<5 { d.activation(20) }
    equal(d.history.order, [B, A, C])
}

test("an external switch right after a commit isn't overridden by the pending commit") {
    var d = threeApps()
    let s = d.open().selected; d.commit(s)    // → B
    d.now += 0.05; d.systemSettles(on: B)
    d.now += 0.1;  d.systemSettles(on: C)     // user clicks C within the pending lifetime
    let r = d.open()
    equal(r.current, C)
    equal(r.selected, B)
}

test("a click on another app right after a same-app switch is recorded") {
    // Chrome C1/C2 (pid 20), Terminal T (pid 10). Switch C1 → C2 (no app
    // activation will come), then click Terminal within the pending lifetime.
    let C1: CGWindowID = 2, C2: CGWindowID = 3, T: CGWindowID = 1
    var d = Driver([Win(id: C1, pid: 20), Win(id: C2, pid: 20), Win(id: T, pid: 10)], focused: C1)
    d.commit(C2)
    d.now += 0.05
    d.frontmostPID = 10; d.axFocused[10] = T   // Chrome never posts its focus event in time
    d.activation(10)
    equal(d.history.order.first, T, "must not be dropped as stale: no activation of ours was coming")
    check(d.pending == nil)
}

// MARK: Apps that raise a window but keep focus on another (seen with Calendar)
//
// Replays the first on-device log. From Claude, the user switched to one of
// two Calendar windows. Calendar raised it but kept reporting its other
// window as focused, so quick taps bounced between the two Calendar windows
// and Claude, the genuinely previous window, sank to third place.

let T: CGWindowID = 1, K1: CGWindowID = 2, K2: CGWindowID = 3
func calendarSetup() -> Driver {
    // Claude T (pid 10) in front; Calendar K1 (focused within Calendar) and K2 (pid 20).
    Driver([Win(id: T, pid: 10), Win(id: K1, pid: 20), Win(id: K2, pid: 20)], focused: T)
}

test("switching to a raised-but-not-focused window: a quick tap goes back, not sideways") {
    var d = calendarSetup()
    d.commit(K2)
    d.now += 0.04
    d.systemSettles(on: K2, focusFollows: false)   // K2 in front, Calendar still says K1
    d.now += 0.2                                     // the activation already arrived
    let r = d.open()
    equal(r.current, K2, "the user is looking at K2")
    equal(r.selected, T, "previously this was K2 again: the window already on screen")
}

test("…and it still holds long after the pending lifetime") {
    var d = calendarSetup()
    d.commit(K2); d.now += 0.04
    d.systemSettles(on: K2, focusFollows: false)
    d.now += 30
    let r = d.open()
    equal(r.current, K2)
    equal(r.list, [K2, T, K1])
    equal(r.selected, T)
}

test("…and repeated quick taps toggle between the two most recent windows") {
    var d = calendarSetup()
    var seen: [CGWindowID] = []
    for _ in 0..<6 {
        let s = d.open().selected
        d.commit(s); d.now += 0.04
        // Calendar never moves focus to K2; everything else behaves normally.
        d.systemSettles(on: s, focusFollows: s != K2)
        d.now += 0.4
        seen.append(s)
    }
    equal(seen, [K1, T, K1, T, K1, T], "starting from T, the most recent other window is K1")
    var d2 = calendarSetup()
    d2.commit(K2); d2.now += 0.04; d2.systemSettles(on: K2, focusFollows: false); d2.now += 0.4
    var seen2: [CGWindowID] = []
    for _ in 0..<6 {
        let s = d2.open().selected
        d2.commit(s); d2.now += 0.04
        d2.systemSettles(on: s, focusFollows: s != K2)
        d2.now += 0.4
        seen2.append(s)
    }
    equal(seen2, [T, K2, T, K2, T, K2], "from K2, taps alternate K2 ↔ T, never K1")
}

test("the last commit stops counting once another window of the app comes to the front") {
    var d = calendarSetup()
    d.commit(K2); d.now += 0.04
    d.systemSettles(on: K2, focusFollows: false)
    d.now += 2
    // User clicks K1. Calendar already reported K1 as focused, so no AX event.
    d.systemSettles(on: K1, notify: false)
    let r = d.open()
    equal(r.current, K1)
    equal(r.selected, K2)
}

test("the last commit stops counting once the user switches to another app") {
    var d = calendarSetup()
    d.commit(K2); d.now += 0.04
    d.systemSettles(on: K2, focusFollows: false)
    d.now += 2
    d.externalFocus(T)                       // click Claude
    check(d.state.lastCommit == nil, "an external promotion drops it")
    d.now += 2
    d.frontmostPID = 20                      // Dock click back to Calendar: K2 still its front window
    d.activation(20)                         // Calendar reports K1
    let r = d.open()
    equal(r.current, K1, "after an external switch, the app's own report is used again")
}

test("current(): lastCommit counts only while it is the frontmost app's front window") {
    let last = PendingCommit(pid: 20, windowID: K2, now: 0)
    var asked = false
    let (id, src) = WindowFocus.current(pending: nil, lastCommit: last, frontmostAppFront: K2,
                                        now: 50, visible: [T, K1, K2]) { asked = true; return K1 }
    equal(id, K2); equal(src, .lastCommit); check(!asked, "no AX round trip needed")
    equal(WindowFocus.current(pending: nil, lastCommit: last, frontmostAppFront: K1,
                              now: 50, visible: [T, K1, K2]) { K1 }.1, .system)
    equal(WindowFocus.current(pending: nil, lastCommit: last, frontmostAppFront: K2,
                              now: 50, visible: [T, K1]) { K1 }.1, .system, "closed since")
}

test("fixed mode: tiles never move, a tap walks to the next tile") {
    var d = threeApps()
    d.recentlyUsed = false
    equal(d.settledTap(), B)
    equal(d.settledTap(), C)
    equal(d.settledTap(), A)
    equal(d.history.order, [A, B, C])
}

test("fixed mode: a rapid double tap advances two tiles, not three") {
    var d = threeApps()
    d.recentlyUsed = false
    let t1 = d.open().selected; d.commit(t1)
    d.now += 0.02
    equal(d.open().selected, C)
}

test("reverse (Shift) tap selects the oldest window") {
    var d = threeApps()
    d.externalFocus(C); d.externalFocus(B); d.externalFocus(A)   // [A, B, C]
    equal(d.open(reverse: true).selected, C)
}

test("1,000 settled toggles always alternate between the same two windows") {
    var d = threeApps()
    var ok = true
    for i in 0..<1000 {
        let s = d.settledTap()
        if s != (i % 2 == 0 ? B : A) { ok = false; break }
    }
    check(ok, "toggle sequence diverged")
    equal(d.history.order, [A, B, C])
}

test("1,000 rapid unsettled toggles also alternate") {
    var d = threeApps()
    var ok = true
    for i in 0..<1000 {
        let s = d.open().selected; d.commit(s)
        d.now += 0.02                     // never let macOS catch up within the gesture
        if s != (i % 2 == 0 ? B : A) { ok = false; break }
        if i % 7 == 6 { d.now += 2; d.systemSettles(on: s) }  // occasionally it does
    }
    check(ok, "rapid toggle sequence diverged")
}

test("property: random external switches and taps keep head == truly focused window") {
    // Deterministic LCG so failures are reproducible.
    var seed: UInt64 = 0xC0FFEE
    func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }

    let ids: [CGWindowID] = [1, 2, 3, 4, 5, 6]
    var d = Driver(ids.map { Win(id: $0, pid: pid_t(10 * Int($0))) }, focused: 1)
    var reference: [CGWindowID] = d.history.order   // independent MRU model of true focus

    func touch(_ id: CGWindowID) { reference.removeAll { $0 == id }; reference.insert(id, at: 0) }

    var ok = true
    for step in 0..<5000 {
        if next(3) == 0 {
            let id = ids[next(ids.count)]
            d.externalFocus(id); touch(id)
        } else {
            let steps = 1 + next(3)              // hold and press Tab 1…3 times
            let r = d.open()
            let idx = (r.list.firstIndex(of: r.selected)! + steps - 1) % r.list.count
            let target = r.list[idx]
            if r.list != reference { ok = false; print("    step \(step): list \(r.list) ≠ reference \(reference)"); break }
            d.commit(target); d.now += 0.05; d.systemSettles(on: target); d.now += 0.3
            touch(target)
        }
        if d.history.order.first != d.trulyFocused { ok = false; print("    step \(step): head \(d.history.order.first!) ≠ focused \(d.trulyFocused!)"); break }
    }
    check(ok, "history diverged from the true focus order")
}

// MARK: - In-app focus changes (WindowFocus.onFocusedWindowChanged)

test("in-app focus change promotes that window") {
    equal(WindowFocus.onFocusedWindowChanged(pid: 20, windowID: 5, pending: nil, now: 0),
          .init(decision: .promote(5), clearPending: false))
}

test("while a commit settles, only the committed window gaining focus counts") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(WindowFocus.onFocusedWindowChanged(pid: 20, windowID: 77, pending: p, now: 10.1),
          .init(decision: .ignoreStale, clearPending: false), "sibling reported before the raise")
    equal(WindowFocus.onFocusedWindowChanged(pid: 10, windowID: A, pending: p, now: 10.1),
          .init(decision: .ignoreStale, clearPending: false), "a last event from the app being left")
    equal(WindowFocus.onFocusedWindowChanged(pid: 20, windowID: B, pending: p, now: 10.1),
          .init(decision: .promote(B), clearPending: true))
}

test("after the pending lifetime, an in-app change is a normal promotion") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(WindowFocus.onFocusedWindowChanged(pid: 20, windowID: 77, pending: p, now: 12),
          .init(decision: .promote(77), clearPending: true))
}

test("⌘` between two windows, then another app: a quick tap returns to the window last used") {
    // Chrome C1/C2 (pid 20), Terminal T (pid 10). Start on C1.
    let C1: CGWindowID = 2, C2: CGWindowID = 3, T: CGWindowID = 1
    var d = Driver([Win(id: C1, pid: 20), Win(id: T, pid: 10), Win(id: C2, pid: 20)], focused: C1)
    d.inAppFocus(C2)                       // ⌘` to C2: only the AX observer sees it
    d.externalFocus(T)                     // click Terminal
    equal(d.history.order, [T, C2, C1])
    equal(d.open().selected, C2, "without in-app tracking this was C1")
}

test("committing to a sibling ignores the app's early report of the old window") {
    let C1: CGWindowID = 2, C2: CGWindowID = 3, T: CGWindowID = 1
    var d = Driver([Win(id: T, pid: 10), Win(id: C1, pid: 20), Win(id: C2, pid: 20)], focused: T)
    d.commit(C2)
    d.now += 0.02
    d.frontmostPID = 20
    d.focusChanged(20, to: C1)             // Chrome briefly reports C1
    d.activation(20)
    d.focusChanged(20, to: C2)             // then the raise lands
    equal(d.history.order, [C2, T, C1])
    check(d.pending == nil)
}

// MARK: - GestureTracker (Sources/GestureTracker.swift)

print("\nGestureTracker tests")

let tab: UInt16 = 48, esc: UInt16 = 53, letterQ: UInt16 = 12

test("hold modifier + tap trigger cycles and swallows; release commits") {
    var g = GestureTracker(triggerKeyCode: tab)
    equal(g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false), .init(swallow: true, action: .cycle(reverse: false)))
    equal(g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: true), .init(swallow: true, action: .cycle(reverse: true)))
    check(g.isActive)
    equal(g.flagsChanged(modifierHeld: true), nil, "pressing another modifier mid-gesture changes nothing")
    equal(g.flagsChanged(modifierHeld: false), .commit)
    check(!g.isActive)
    equal(g.flagsChanged(modifierHeld: false), nil, "a second release can't commit twice")
}

test("trigger without the modifier passes through untouched") {
    var g = GestureTracker(triggerKeyCode: tab)
    equal(g.keyDown(keyCode: tab, modifierHeld: false, shiftHeld: false), .init(swallow: false, action: nil))
    check(!g.isActive)
}

test("Escape cancels an active gesture and is swallowed; passes through otherwise") {
    var g = GestureTracker(triggerKeyCode: tab)
    equal(g.keyDown(keyCode: esc, modifierHeld: true, shiftHeld: false), .init(swallow: false, action: nil))
    _ = g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false)
    equal(g.keyDown(keyCode: esc, modifierHeld: true, shiftHeld: false), .init(swallow: true, action: .cancel))
    equal(g.flagsChanged(modifierHeld: false), nil, "release after cancel must not commit")
}

test("other keys during a gesture pass through and don't end it") {
    var g = GestureTracker(triggerKeyCode: tab)
    _ = g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false)
    equal(g.keyDown(keyCode: letterQ, modifierHeld: true, shiftHeld: false), .init(swallow: false, action: nil))
    check(g.isActive)
}

test("lost release: the next keystroke commits and is let through") {
    var g = GestureTracker(triggerKeyCode: tab)
    _ = g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false)
    // flagsChanged(up) never delivered (tap was disabled). User types a letter.
    equal(g.keyDown(keyCode: letterQ, modifierHeld: false, shiftHeld: false), .init(swallow: false, action: .commit))
    check(!g.isActive)
}

test("lost release: a bare trigger keystroke commits and is let through") {
    var g = GestureTracker(triggerKeyCode: tab)
    _ = g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false)
    equal(g.keyDown(keyCode: tab, modifierHeld: false, shiftHeld: false), .init(swallow: false, action: .commit))
}

test("lost release: Escape still cancels (and is swallowed) rather than committing") {
    var g = GestureTracker(triggerKeyCode: tab)
    _ = g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false)
    equal(g.keyDown(keyCode: esc, modifierHeld: false, shiftHeld: false), .init(swallow: true, action: .cancel))
    check(!g.isActive)
}

test("lost release: resync from live flags commits once; held modifier changes nothing") {
    var g = GestureTracker(triggerKeyCode: tab)
    _ = g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false)
    equal(g.resync(modifierHeld: true), nil)
    check(g.isActive)
    equal(g.resync(modifierHeld: false), .commit)
    equal(g.resync(modifierHeld: false), nil)
}

test("resync with no gesture in progress does nothing") {
    var g = GestureTracker(triggerKeyCode: tab)
    equal(g.resync(modifierHeld: false), nil)
}

test("end() stops swallowing Escape after a card click") {
    var g = GestureTracker(triggerKeyCode: tab)
    _ = g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false)
    g.end()
    equal(g.keyDown(keyCode: esc, modifierHeld: true, shiftHeld: false), .init(swallow: false, action: nil))
    equal(g.flagsChanged(modifierHeld: false), nil)
}

test("back-to-back gestures: the second one commits on its own release") {
    // Regression guard: a queued close() for gesture 1 used to reset state
    // that gesture 2 had already set. The tracker alone owns that state now.
    var g = GestureTracker(triggerKeyCode: tab)
    _ = g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false)
    equal(g.flagsChanged(modifierHeld: false), .commit)
    equal(g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false).action, .cycle(reverse: false))
    equal(g.flagsChanged(modifierHeld: false), .commit)
}

test("rebinding the trigger keeps an in-progress gesture and uses the new key") {
    var g = GestureTracker(triggerKeyCode: tab)
    _ = g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false)
    g = g.withTriggerKeyCode(50)
    check(g.isActive)
    equal(g.keyDown(keyCode: 50, modifierHeld: true, shiftHeld: false).action, .cycle(reverse: false))
    equal(g.keyDown(keyCode: tab, modifierHeld: true, shiftHeld: false), .init(swallow: false, action: nil))
}

test("property: random event streams never leave a gesture active with the modifier up") {
    var seed: UInt64 = 0xBADC0DE
    func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
    var g = GestureTracker(triggerKeyCode: tab)
    var held = false
    var commits = 0, cycles = 0, ok = true
    for _ in 0..<20_000 {
        switch next(6) {
        case 0: held.toggle(); if g.flagsChanged(modifierHeld: held) == .commit { commits += 1 }
        case 1: held.toggle()                                   // release/press lost by the tap
        case 2: if g.resync(modifierHeld: held) == .commit { commits += 1 }
        default:
            let key = [tab, tab, esc, letterQ][next(4)]
            let r = g.keyDown(keyCode: key, modifierHeld: held, shiftHeld: next(2) == 0)
            if case .cycle = r.action { cycles += 1 }
            if r.action == .commit { commits += 1 }
            if r.swallow && !held { ok = false }                 // never eat keys without the modifier
        }
        // "Active with the modifier up" is the lost-release state. The
        // release-check timer must always get out of it in one resync.
        if g.isActive && !held {
            if g.resync(modifierHeld: false) == .commit { commits += 1 } else { ok = false }
        }
        if g.isActive && !held { ok = false }
    }
    check(ok, "tracker swallowed a key or stayed active with the modifier up")
    check(cycles > 0 && commits > 0, "stream didn't exercise the machine (cycles \(cycles), commits \(commits))")
}

// MARK: - LegacyDefaultsMigration (Sources/AppBundle.swift)
//
// These test the pure `plan` step. They never read or write real
// preferences.

print("\nSettings migration tests")

func plan(done: Bool = false, legacy: [String: Any]?, existing: Set<String> = []) -> LegacyDefaultsMigration.Plan {
    LegacyDefaultsMigration.plan(alreadyDone: done, legacy: legacy, hasValue: { existing.contains($0) })
}

test("copies every old setting the new domain doesn't have, and marks done") {
    let p = plan(legacy: ["switch.modifier": "option", "lastSeenDesignatedRequirement": "dr-old"])
    equal(Set(p.copy.keys), ["switch.modifier", "lastSeenDesignatedRequirement"],
          "the identity record must carry over so AppIdentity sees the change")
    equal(p.copy["switch.modifier"] as? String, "option")
    check(p.markDone)
}

test("never overwrites a setting already made under the new id") {
    let p = plan(legacy: ["switch.modifier": "option", "switch.triggerKey": "grave"], existing: ["switch.modifier"])
    equal(Set(p.copy.keys), ["switch.triggerKey"])
}

test("runs once: when already done, nothing is copied or written") {
    let p = plan(done: true, legacy: ["switch.triggerKey": "grave"])
    check(p.copy.isEmpty && !p.markDone)
}

test("a Mac that never ran the old id still marks done, so the check isn't repeated") {
    let p = plan(legacy: nil)
    check(p.copy.isEmpty && p.markDone)
}

test("the completion flag itself is never copied from the old domain") {
    let p = plan(legacy: [LegacyDefaultsMigration.completedKey: true, "switch.modifier": "option"])
    equal(Set(p.copy.keys), ["switch.modifier"])
}

test("the app's identifiers differ and the legacy one is the old placeholder") {
    check(AppBundle.identifier != AppBundle.legacyIdentifier)
    equal(AppBundle.legacyIdentifier, "com.example.windowswitcher")
}

// MARK: - Summary

print(failures == 0 ? "\nAll \(checks) checks passed." : "\n\(failures) of \(checks) checks FAILED.")
exit(failures == 0 ? 0 : 1)
