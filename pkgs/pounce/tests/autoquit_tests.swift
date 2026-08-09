import Foundation

// AutoQuitPolicy (AutoQuitPolicy.swift): which apps a windowless snapshot means
// to quit — and, mostly, which it doesn't.
//
// This is the half of auto-quit worth testing, because every bug it can have is
// the same bug: quitting an app the user was still using. The effects it drives
// (the AX re-check, the terminate) live in AutoQuit.swift and need a running
// app to mean anything; the decision doesn't.

func runAutoQuitTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // `standard` defaults to `windows` — the ordinary case, where every window
    // the walk kept is a document window. Pass it explicitly for the dialog case.
    func app(_ pid: pid_t, _ bundleId: String?, windows: Int, standard: Int? = nil,
             responded: Bool = true) -> AppWindowCensus {
        AppWindowCensus(pid: pid, name: "App \(pid)", bundleId: bundleId,
                        responded: responded, windows: windows, standardWindows: standard)
    }
    func quitting(_ result: [AppWindowCensus]) -> [pid_t] { result.map(\.pid) }

    // ── the happy path ──────────────────────────────────────────────────────
    // Had a window, lost it, gets quit. One snapshot each way.
    var p = AutoQuitPolicy()
    check(quitting(p.step([app(1, "com.example.a", windows: 2)])).isEmpty,
          "an app with windows is never a candidate")
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])) == [1],
          "an app that just lost its last window is quit")

    // ── never seen with a window ────────────────────────────────────────────
    // The daemon starts, an app is already windowless (or is one of the many
    // that live in the menu bar and open a window only later). Nothing happens.
    p = AutoQuitPolicy()
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])).isEmpty,
          "an app windowless since the first snapshot is left alone")
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])).isEmpty,
          "…and stays left alone however many snapshots pass")
    _ = p.step([app(1, "com.example.a", windows: 1)])
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])) == [1],
          "…until it does open a window, and closes it")

    // ── the timeout ambiguity ───────────────────────────────────────────────
    // An app that missed the AX walk's 100ms deadline reports zero windows for
    // the same reason a windowless one does. Never act on that.
    p = AutoQuitPolicy()
    _ = p.step([app(1, "com.example.a", windows: 3)])
    check(quitting(p.step([app(1, "com.example.a", windows: 0, responded: false)])).isEmpty,
          "an app that didn't answer the AX walk is not quit")
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])) == [1],
          "…and is quit on the next pass it does answer")

    // ── exclusions ──────────────────────────────────────────────────────────
    p = AutoQuitPolicy(excluded: ["com.apple.finder"])
    _ = p.step([app(1, "com.apple.finder", windows: 1), app(2, "com.example.b", windows: 1)])
    check(quitting(p.step([app(1, "com.apple.finder", windows: 0),
                           app(2, "com.example.b", windows: 0)])) == [2],
          "an excluded bundle id is skipped, its neighbours are not")

    // An app with no bundle id at all can't be named in `exclude`, so it can't be
    // opted out — which means it never gets opted in.
    p = AutoQuitPolicy()
    _ = p.step([app(1, nil, windows: 1)])
    check(quitting(p.step([app(1, nil, windows: 0)])).isEmpty,
          "an app without a bundle id is never quit")

    // ── ask once ────────────────────────────────────────────────────────────
    // terminate() is a request an app may refuse (an unsaved-changes sheet). It
    // then sits there windowless, and every later snapshot would re-ask forever.
    p = AutoQuitPolicy()
    _ = p.step([app(1, "com.example.a", windows: 1)])
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])) == [1], "asked once")
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])).isEmpty,
          "an app that declined the quit is not asked again")
    _ = p.step([app(1, "com.example.a", windows: 1)])
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])) == [1],
          "…until it opens a window again, which re-arms it")

    // An app that declines the quit by putting up a modal alert must not re-arm
    // on that alert: cancelling it would return the app to zero windows, quit it
    // again, and put the same alert back — a loop with no way out but ⌘Q.
    p = AutoQuitPolicy()
    _ = p.step([app(1, "com.example.a", windows: 1)])
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])) == [1], "asked once")
    _ = p.step([app(1, "com.example.a", windows: 1, standard: 0)])   // "really quit?"
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])).isEmpty,
          "a modal alert is not a window that re-arms the quit")
    _ = p.step([app(1, "com.example.a", windows: 1, standard: 1)])
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])) == [1],
          "…but a real window still does")

    // The alert is a window for the OTHER purpose, though: an app whose first
    // window ever is a dialog, then closed, is a fair candidate.
    p = AutoQuitPolicy()
    _ = p.step([app(1, "com.example.a", windows: 1, standard: 0)])
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])) == [1],
          "a dialog still counts as having had a window at all")

    // ── pid reuse ───────────────────────────────────────────────────────────
    // The real hazard of keeping state per pid: an app dies, macOS hands its pid
    // to something new, and the new app inherits "this one had windows" — so it
    // gets quit before it has drawn anything.
    p = AutoQuitPolicy()
    _ = p.step([app(1, "com.example.a", windows: 1)])
    _ = p.step([])                                   // app 1 exits
    check(quitting(p.step([app(1, "com.example.new", windows: 0)])).isEmpty,
          "a recycled pid does not inherit the dead app's window history")

    // Same for the ask: the pid that declined a quit is gone, and its successor
    // must be judged from scratch rather than treated as already-asked.
    p = AutoQuitPolicy()
    _ = p.step([app(1, "com.example.a", windows: 1)])
    check(quitting(p.step([app(1, "com.example.a", windows: 0)])) == [1], "asked once")
    _ = p.step([])
    _ = p.step([app(1, "com.example.new", windows: 1)])
    check(quitting(p.step([app(1, "com.example.new", windows: 0)])) == [1],
          "a recycled pid does not inherit the dead app's asked flag")

    // ── several apps at once ────────────────────────────────────────────────
    // Nothing here is per-app state that leaks: closing two windows in the same
    // pass quits both, and an app that kept one is untouched.
    p = AutoQuitPolicy()
    _ = p.step([app(1, "com.example.a", windows: 1), app(2, "com.example.b", windows: 1),
                app(3, "com.example.c", windows: 2)])
    check(quitting(p.step([app(1, "com.example.a", windows: 0), app(2, "com.example.b", windows: 0),
                           app(3, "com.example.c", windows: 1)])) == [1, 2],
          "two apps closing together are both quit, the one still open is not")

    if failures == 0 { print("ok — all auto-quit policy tests passed") }
    return failures
}
