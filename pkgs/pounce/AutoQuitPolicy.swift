import Foundation

// MARK: - Census

// What one snapshot pass learned about one running app. `responded` is the load-
// bearing field: the AX walk gives each app 100ms to answer, and an app that
// misses that deadline is skipped entirely — indistinguishable, from the window
// list alone, from an app that answered "I have none". Quitting on that
// ambiguity would kill whatever app happened to be busy, so the tracker reports
// the two states separately and the policy below only ever acts on a real
// answer.
struct AppWindowCensus: Equatable {
    let pid: pid_t
    let name: String
    let bundleId: String?
    let responded: Bool
    // Switchable windows: ordinary document windows plus dialogs. Zero here is
    // what "you closed the last one" looks like.
    let windows: Int
    // Of those, the ordinary ones. A modal alert counts in `windows` but not
    // here, which is the difference between "the app is back in use" and "the app
    // is asking whether you really meant to quit it" — see `asked` below.
    let standardWindows: Int

    init(pid: pid_t, name: String, bundleId: String?, responded: Bool,
         windows: Int, standardWindows: Int? = nil) {
        self.pid = pid
        self.name = name
        self.bundleId = bundleId
        self.responded = responded
        self.windows = windows
        self.standardWindows = standardWindows ?? windows
    }
}

// MARK: - AutoQuitPolicy

// Decides which apps just lost their last window and should be asked to quit —
// the Windows-style "closing the last window closes the program", which macOS
// deliberately doesn't do.
//
// Pure and Foundation-only so `tests/run.sh` can compile it: every effect (the
// re-check, the quit itself) lives in AutoQuit.swift. All the interesting
// behaviour is in what this REFUSES to schedule, and each guard is a real app
// this would otherwise have killed:
//
//   never seen with a window  an app already windowless when the daemon started,
//                             and every menu-bar-ish app that opens one later
//   didn't answer             a busy app whose AX reply timed out (see above)
//   no bundle id              nothing the user could put in `exclude`, so it
//                             gets the benefit of the doubt
//   already asked             a quit the app declined (unsaved-changes sheet) —
//                             ask once, not once per snapshot until it dies
//
// Every set is keyed by pid, so each pass drops the pids that are gone: pids are
// recycled, and inheriting "this one had windows" from a dead app is exactly how
// a fresh app gets quit before it draws.
struct AutoQuitPolicy {
    // Bundle ids never quit. Replaced wholesale from config, not merged — see
    // AutoQuitSettings.exclude.
    var excluded: Set<String>

    private var seenWithWindows: Set<pid_t> = []
    private var asked: Set<pid_t> = []

    init(excluded: [String] = []) {
        self.excluded = Set(excluded)
    }

    // Fold in one snapshot; returns the apps to quit. Call order is the caller's
    // ordering — this doesn't sort.
    mutating func step(_ census: [AppWindowCensus]) -> [AppWindowCensus] {
        let live = Set(census.map(\.pid))
        seenWithWindows.formIntersection(live)
        asked.formIntersection(live)

        var quit: [AppWindowCensus] = []
        for app in census {
            guard app.windows == 0 else {
                seenWithWindows.insert(app.pid)
                // Re-armed: an app that opened a real window again is a candidate
                // again, even if it once refused a quit. Deliberately keyed on
                // STANDARD windows, not on `windows`: an app that declines a quit
                // with a modal alert ("uploads in progress — really quit?") would
                // otherwise re-arm on its own alert, and cancelling it would put
                // the same alert straight back up, forever.
                if app.standardWindows > 0 { asked.remove(app.pid) }
                continue
            }
            guard app.responded,
                  seenWithWindows.contains(app.pid),
                  !asked.contains(app.pid),
                  let bundleId = app.bundleId,
                  !excluded.contains(bundleId)
            else { continue }
            asked.insert(app.pid)
            quit.append(app)
        }
        return quit
    }
}
