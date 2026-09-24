import Foundation

// AppLaunchPlan.decide / PackagerAgent.loaded: a Launch Services start of the
// app (login-time restore, a pounce:// link) must not self-register the
// SMAppService agent when haus or brew already manages the daemon — that job
// wins the socket at the next login and runs without the packager's
// environment. A drag-install, with no packager, must still register: that is
// the whole point of LoginItem.swift.

func runPackagerTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    check(AppLaunchPlan.decide(daemonAlive: true, packager: nil) == .summon,
          "a running daemon is summoned, drag-install")
    check(AppLaunchPlan.decide(daemonAlive: true, packager: "com.hausfold.pounce") == .summon,
          "a running daemon is summoned, packager present")
    check(AppLaunchPlan.decide(daemonAlive: false, packager: nil) == .register,
          "a drag-install with no daemon still self-registers")
    check(AppLaunchPlan.decide(daemonAlive: false, packager: "com.hausfold.pounce")
            == .deferTo("com.hausfold.pounce"),
          "haus's agent loaded: defer, never register")
    check(AppLaunchPlan.decide(daemonAlive: false, packager: "homebrew.mxcl.pounce")
            == .deferTo("homebrew.mxcl.pounce"),
          "brew services loaded: defer, never register")

    check(PackagerAgent.loaded(isLoaded: { _ in false }) == nil,
          "no packager label loaded reads as drag-install")
    check(PackagerAgent.loaded(isLoaded: { $0 == "homebrew.mxcl.pounce" }) == "homebrew.mxcl.pounce",
          "brew's label is recognised")
    check(PackagerAgent.loaded(isLoaded: { _ in true }) == "com.hausfold.pounce",
          "haus wins when both are loaded")

    // The real probe against a label nobody loads: launchctl print exits
    // non-zero, which must read as not-loaded rather than loaded.
    check(!PackagerAgent.launchctlKnows("com.hausfold.pounce.tests.nonexistent"),
          "an unknown label is not loaded")

    if failures == 0 { print("ok — all packager-agent tests passed") }
    return failures
}
