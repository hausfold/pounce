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

    if failures == 0 { print("ok — all update-nudge tests passed") }
    return failures
}
