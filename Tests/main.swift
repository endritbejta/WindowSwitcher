// Unit tests for the window-ordering rules in Sources/WindowHistory.swift.
//
// Run with `./build.sh test`. That compiles this file together with
// WindowHistory.swift only. No AppKit, no permissions and no running apps are
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
// `Driver` replays what `WindowOrderManager` and `SwitcherController` do:
//   * `open` is `orderedWindows()` followed by the selection in `open()`;
//   * `commit` is `noteCommit`;
//   * `activation` is `appDidActivate`.
// It feeds them the same pure functions with scripted system state, so lag,
// stale notifications and Accessibility reporting the wrong window can be set
// up exactly.

struct Win { let id: CGWindowID; let pid: pid_t; var onScreen = true }

struct Driver {
    var history = WindowHistory()
    var pending: PendingCommit?
    var now: Double = 100
    var recentlyUsed = true

    let ownPID: pid_t = 999
    var windows: [Win]               // front-to-back z-order; only on-screen ones are visible
    var closed = Set<CGWindowID>()   // ids no longer existing
    var frontmostPID: pid_t?         // NSWorkspace.frontmostApplication
    var axFocused: [pid_t: CGWindowID] = [:]   // what Accessibility reports per app
    var axQueries = 0

    init(_ windows: [Win], focused: CGWindowID) {
        self.windows = windows
        let w = windows.first { $0.id == focused }!
        frontmostPID = w.pid
        for win in windows.reversed() { axFocused[win.pid] = win.id }  // front-most window per app
        axFocused[w.pid] = focused
        // Seed like `init()`: arrange the current z-order.
        _ = history.arrange(visible: windows.map(\.id))
    }

    var visible: [Win] { windows.filter { $0.onScreen && !closed.contains($0.id) } }
    func pid(of id: CGWindowID) -> pid_t { windows.first { $0.id == id }!.pid }

    /// The settled, user-visible truth: what really has focus.
    var trulyFocused: CGWindowID? { frontmostPID.flatMap { axFocused[$0] } }

    /// Opens the switcher and returns the list and the pre-selected window.
    mutating func open(reverse: Bool = false) -> (list: [CGWindowID], selected: CGWindowID, current: CGWindowID?) {
        let vis = visible
        let visIDs = Set(vis.map(\.id))
        let front = frontmostPID, own = ownPID, ax = axFocused
        var queries = 0
        let current = WindowFocus.current(pending: pending, now: now, visible: visIDs) {
            // Mirrors WindowOrderManager.systemFocusedWindow.
            guard let pid = front, pid != own else { return nil }
            queries += 1
            if let id = ax[pid], visIDs.contains(id) { return id }
            return vis.first { $0.pid == pid }?.id
        }
        axQueries += queries
        let existing = Set(windows.map(\.id)).subtracting(closed)
        let list = history.prepareOpen(visible: vis.map(\.id), existing: existing,
                                       current: current, recentlyUsed: recentlyUsed)
        let index = WindowHistory.initialSelection(
            count: list.count, anchor: list.firstIndex(of: current ?? 0), reverse: reverse)
        return (list, list[index], current)
    }

    mutating func commit(_ id: CGWindowID) {
        pending = PendingCommit(pid: pid(of: id), windowID: id, now: now)
        if recentlyUsed { history.promote(id) }
    }

    /// An NSWorkspace didActivateApplication notification for `pid`, handled now.
    mutating func activation(_ pid: pid_t) {
        let ax = axFocused
        var queried = false
        let outcome = WindowFocus.onActivation(
            notifiedPID: pid, frontmostPID: frontmostPID, ownPID: ownPID,
            pending: pending, now: now) { queried = true; return ax[pid] }
        if queried { axQueries += 1 }
        if outcome.clearPending { pending = nil }
        if case .promote(let id) = outcome.decision, recentlyUsed { history.promote(id) }
    }

    /// The system finishes carrying out a switch to `id`.
    mutating func systemSettles(on id: CGWindowID, notify: Bool = true) {
        let p = pid(of: id)
        let changedApp = frontmostPID != p
        frontmostPID = p
        axFocused[p] = id
        if notify && changedApp { activation(p) }
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
    let id = WindowFocus.current(pending: p, now: 10.2, visible: [A, B]) { asked = true; return A }
    equal(id, B); check(!asked, "system should not be queried")
}

test("an expired pending commit defers to the system") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(WindowFocus.current(pending: p, now: 10 + PendingCommit.lifetime + 0.01, visible: [A, B]) { A }, A)
}

test("a pending commit whose window vanished defers to the system") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(WindowFocus.current(pending: p, now: 10.1, visible: [A]) { A }, A)
}

test("a system-focused window that isn't listed gives no current window") {
    equal(WindowFocus.current(pending: nil, now: 0, visible: [A, B]) { 42 }, nil)
}

// MARK: - WindowFocus.onActivation

func activation(notified: pid_t, frontmost: pid_t?, pending: PendingCommit? = nil,
                now: Double = 10.1, ax: CGWindowID? = 7, axCalled: UnsafeMutablePointer<Bool>? = nil) -> WindowFocus.Outcome {
    WindowFocus.onActivation(notifiedPID: notified, frontmostPID: frontmost, ownPID: 999,
                             pending: pending, now: now) { axCalled?.pointee = true; return ax }
}

test("own app's activation is ignored") {
    equal(activation(notified: 999, frontmost: 999).decision, .ignoreOwnApp)
}

test("a stale notification (frontmost has moved on) is ignored") {
    equal(activation(notified: 20, frontmost: 10).decision, .ignoreStale)
}

test("a stale notification for the pending app also clears the pending commit") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(activation(notified: 20, frontmost: 10, pending: p), .init(decision: .ignoreStale, clearPending: true))
}

test("the activation we asked for promotes the committed window, not AX's sibling") {
    var called = false
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    let o = activation(notified: 20, frontmost: 20, pending: p, ax: 77, axCalled: &called)
    equal(o, .init(decision: .promote(B), clearPending: true))
    check(!called, "AX should not be queried for our own commit")
}

test("an external activation promotes AX's focused window and supersedes pending") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(activation(notified: 30, frontmost: 30, pending: p, ax: C), .init(decision: .promote(C), clearPending: true))
}

test("an activation after the pending commit expired is treated as external") {
    let p = PendingCommit(pid: 20, windowID: B, now: 10)
    equal(activation(notified: 20, frontmost: 20, pending: p, now: 12, ax: 77),
          .init(decision: .promote(77), clearPending: true))
}

test("an app with no AX focused window promotes nothing") {
    equal(activation(notified: 30, frontmost: 30, ax: nil).decision, .ignoreNoFocusedWindow)
}

test("unknown frontmost (nil) does not count as stale") {
    equal(activation(notified: 30, frontmost: nil, ax: C).decision, .promote(C))
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

// MARK: - Summary

print(failures == 0 ? "\nAll \(checks) checks passed." : "\n\(failures) of \(checks) checks FAILED.")
exit(failures == 0 ? 0 : 1)
