import ApplicationServices
import Foundation

// MARK: - The Accessibility grant, answered by the DAEMON

// `--check-accessibility` and `--request-accessibility`, both forwarded over the
// socket to the resident daemon.
//
// They used to call AXIsProcessTrusted() / AXIsProcessTrustedWithOptions() right
// here, and that is not a question about this binary: macOS resolves both
// against the process RESPONSIBLE for the caller, which for a CLI run from a
// shell is the terminal. A throwaway binary TCC has never seen — no bundle id,
// no grant, an ad-hoc signature, a path under /tmp — gets `true` out of BOTH
// calls when run from a granted Ghostty. So:
//
//   - `--check-accessibility` printed `true` while the daemon held nothing. A
//     fresh VM whose TCC row read `kTCCServiceAccessibility|com.hausfold.pounce|0`
//     still drew a green tick in haus's Accessibility card, doctor insisted the
//     grant was fine, and every chord stayed dead (hausfold/haus#738, which
//     stopped reading this flag and reads `pounce doctor --json` instead).
//   - `--request-accessibility` was worse than wrong: from a granted terminal it
//     returned `true` and raised NO PROMPT AT ALL, so the one bootstrap verb
//     silently did nothing exactly when it was needed. From an ungranted one it
//     would have prompted for the TERMINAL, putting the grant on the wrong app.
//
// The daemon is the signed Pounce.app that actually needs the grant, so its own
// AXIsProcessTrusted() is the answer and a prompt it raises names IT. This is
// the same forwarding `focus` and `--transform` do (Daemon.request), for the
// same reason — with one deliberate difference: **there is no local fallback.**
// Those two fall back because a local keypress still works when the terminal
// holds the grant; here a local answer is the bug itself, and a local prompt
// would grant Accessibility to the terminal. With no daemon both say `unknown`
// and exit 1 — the code the help text already spends on "a daemon that isn't
// running" — because an unknown must never read as granted. `doctor --json`
// publishes null in the same spot for the same reason, and
// `[ "$(pounce --check-accessibility)" = "true" ]` stays false either way.
enum AccessibilityGrant {
    // MARK: Client side

    // Prints `true` / `false` / `unknown`. A definite answer exits 0 whichever
    // way it went — same as `--check-bluetooth`, and the contract every existing
    // caller was written against; only the genuinely unknown case is nonzero.
    static func check() -> Never {
        guard let status = daemonStatus(),
              // Absent rather than false: every daemon that ever answered STATUS
              // has carried this, so a missing key is a daemon we don't
              // understand, not a denial. Same rule as request()'s gate.
              let trusted = status["accessibility"] as? Bool
        else { return unknown(verb: "--check-accessibility") }
        print(trusted ? "true" : "false")
        exit(0)
    }

    // Fires the system "add to Accessibility" prompt IN THE DAEMON, then prints
    // the trust state the daemon reports. `false` here is the normal answer for
    // a prompt just raised: TCC hands the dialog to the user asynchronously and
    // the daemon's own watchAccessibility (2s poll) arms the chords when they
    // tick the box, so there is nothing to wait for and nothing to restart.
    static func request() -> Never {
        guard let status = daemonStatus() else { return unknown(verb: "--request-accessibility") }
        // Capability gate before the verb, never after. A daemon predating
        // AXPROMPT treats an unknown payload as picker input and DRAWS it, so
        // asking an older daemon to prompt would put a one-row picker on the
        // user's screen — the loudest possible failure for a bootstrap verb.
        // Mirrors ListMode's `commands` gate.
        guard status["accessibilityPrompt"] as? Bool == true else {
            print("unknown")
            // Usually NOT a stale install: it is this repo's own `./result/bin/pounce`
            // talking to the installed release daemon, which a restart leaves
            // exactly as old. Name the verbs that actually replace it.
            warn("the running pounce daemon (\(status["version"] as? String ?? "?")) is older than this CLI and can't raise the prompt itself; replace it first (`bench try` from a checkout, `brew upgrade pounce` otherwise), or restart it if it is already the newer build, then ask again")
            exit(1)
        }
        guard let reply = Daemon.request("AXPROMPT\n") else {
            return unknown(verb: "--request-accessibility")
        }
        print(reply == "true" ? "true" : "false")
        exit(0)
    }

    // One STATUS round trip: liveness, the daemon's own trust state, and what
    // verbs it knows. nil when nothing answered.
    private static func daemonStatus() -> [String: Any]? {
        // The escape hatch ClientMode and `pounce list` honour, for the same
        // reason — a build under test must not answer out of the INSTALLED
        // daemon. Here it means "no daemon": there is no honest local answer to
        // fall back to.
        if ProcessInfo.processInfo.environment["POUNCE_NO_DAEMON"] == "1" { return nil }
        // A COLD-START BUDGET, not a retry loop. `brew services start pounce`
        // and the login item both return before the daemon binds its socket, and
        // the README's install block runs `--request-accessibility` on the very
        // next line — without this it would tell someone to start a daemon they
        // just started. Only a total no-answer waits; a daemon that replies
        // (even one too old) returns on the first trip, so the common path pays
        // nothing and a scripted check pays this once, on the way to failing.
        let deadline = Date().addingTimeInterval(coldWaitBudget)
        while true {
            if let reply = Daemon.request("STATUS\n"),
               let obj = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] {
                return obj
            }
            if Date() >= deadline { return nil }
            usleep(150_000)
        }
    }

    // Long enough for a launchd/Homebrew start to bind the socket, short enough
    // that `pounce --check-accessibility` in a script still feels immediate.
    private static let coldWaitBudget: TimeInterval = 2.0

    private static func unknown(verb: String) -> Never {
        print("unknown")
        warn("no pounce daemon answered, and this process can only see the TERMINAL's grant, not pounce's — start the daemon (`brew services start pounce`, or open Pounce.app) and run `\(verb)` again")
        exit(1)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data(("pounce: " + message + "\n").utf8))
    }

    // MARK: Daemon side

    // Answers the AXPROMPT verb. Called from handleClient on its own connection
    // thread, alongside the AXIsProcessTrusted() that STATUS already reports
    // from there — the prompt is drawn by tccd, not by us, so there is no window
    // of ours to hop to the main queue for, and the call returns without waiting
    // on the user.
    static func promptInDaemon() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
