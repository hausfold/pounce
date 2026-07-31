// Update-nudge tests: the CalVer comparison that decides whether the daemon
// nudges (UpdateCheck.swift). Pure string logic — the exact place an "obvious"
// semver-style rewrite would silently break the same-day suffix ordering, so
// every shape `bench release` can mint is pinned here. Compiled into the same
// test binary as the other suites (tests/run.sh, entry point tests/main.swift);
// run.sh stubs pounceVersion since Version.generated.swift only exists after a
// build.

import Foundation

func runUpdateNudgeTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }
    func newer(_ candidate: String, _ running: String) {
        expect(UpdateNudge.isNewer(candidate, than: running),
               "\(candidate) should be newer than \(running)")
    }
    func notNewer(_ candidate: String, _ running: String) {
        expect(!UpdateNudge.isNewer(candidate, than: running),
               "\(candidate) should NOT be newer than \(running)")
    }

    // Plain date ordering (zero-padded CalVer is lexicographic by design).
    newer("2026.07.30", "2026.07.29")
    newer("2026.08.01", "2026.07.31")
    newer("2027.01.01", "2026.12.31")
    notNewer("2026.07.29", "2026.07.29")
    notNewer("2026.07.28", "2026.07.29")

    // Same-day repeats: the -N suffix sorts after its base and between days.
    newer("2026.07.20-1", "2026.07.20")
    newer("2026.07.20-2", "2026.07.20-1")
    newer("2026.07.22", "2026.07.20-3")
    notNewer("2026.07.20", "2026.07.20-1")

    // The suffix is compared numerically, not as a string — a lexicographic
    // compare would order "-10" before "-2" and silently never nudge past the
    // tenth same-day release.
    newer("2026.07.20-10", "2026.07.20-2")
    notNewer("2026.07.20-2", "2026.07.20-10")

    // Dev/local builds never nudge, whatever the candidate.
    notNewer("2026.07.30", "dev")
    notNewer("2026.07.30", "")

    // Install cohorts. What this decides is the command the nudge tells the
    // user to run, so a misread here sends someone to a command that does
    // nothing for their install — the exact failure this enum exists to stop.
    let home = "/Users/nib"
    func kind(_ path: String, _ want: InstallKind, _ label: String) {
        let got = InstallKind.detect(bundlePath: path, home: home)
        expect(got == want, "\(label): \(path) → \(got), want \(want)")
    }
    kind("/opt/homebrew/Cellar/pounce/2026.07.30/Pounce.app", .homebrew, "brew keg (Apple Silicon)")
    kind("/usr/local/Cellar/pounce/2026.07.30/Pounce.app", .homebrew, "brew keg (Intel prefix)")
    kind("/Applications/Pounce.app", .direct, "drag install")
    kind("\(home)/Applications/Pounce.app", .direct, "per-user drag install")
    kind("/nix/store/abc123-pounce/Applications/Pounce.app", .nix, "bare store path")
    kind("\(home)/.local/state/pounce/Pounce.app", .rice, "rice re-signed copy")
    kind("/Users/nib/src/pounce/Pounce.app", .unknown, "a build tree is nobody's cohort")

    // The rice publishes /Applications/Pounce.app as a symlink INTO the state
    // dir; callers resolve before detecting (as update-pounce.sh's readlink -f
    // does), so the resolved path must win — otherwise a rice user is told to
    // press Return for an install the script will refuse.
    kind("\(home)/.local/state/pounce/current/Pounce.app", .rice, "resolved rice symlink")

    // Only the two cohorts that own their bytes may promise an install.
    for k in [InstallKind.homebrew, .direct] {
        expect(k.canSelfUpdate, "\(k) should self-update")
    }
    for k in [InstallKind.rice, .nix] {
        expect(!k.canSelfUpdate, "\(k) must not promise an install")
    }
    expect(InstallKind.rice.actionHint.contains("haus update"),
           "the rice cohort is told to run haus update")

    // Dismissal ("Skip this version", ⌘⏎) is per-version. The rule that
    // matters is that it EXPIRES: if a dismissal outlived its version, "skip"
    // would quietly become "never nudge me again" and the next release would
    // ship to a user who never hears about it.
    func pins(_ available: String?, _ dismissed: String?, _ want: Bool, _ label: String) {
        let got = UpdateNudge.shouldPin(available: available, dismissed: dismissed)
        expect(got == want, "\(label): pin(available: \(available ?? "nil"), "
                          + "dismissed: \(dismissed ?? "nil")) → \(got), want \(want)")
    }
    pins("2026.07.30", nil, true, "a fresh update pins")
    pins("2026.07.30", "2026.07.30", false, "the dismissed version stays down")
    pins("2026.07.31", "2026.07.30", true, "the NEXT release pins again")
    pins("2026.07.30-1", "2026.07.30", true, "a same-day respin is its own version")
    pins(nil, "2026.07.30", false, "nothing pending, nothing to pin")

    if failures == 0 { print("ok — all update-nudge tests passed") }
    return failures
}
