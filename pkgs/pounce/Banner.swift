import Foundation

// MARK: - The one banner pounce draws

// Every notification the DAEMON raises goes through here: trill when this Mac
// has it, macOS's own banner when it doesn't. The command scripts each carry a
// `notify()` of the same shape (AGENTS.md § Notifications); this is the Swift
// side's single copy, and it is why nothing in this repo writes a bare
// `display notification` (CI fails the build over one).
//
// Resolved at call time rather than through a `trill` on PATH, because pounce
// installs standalone (Homebrew, a release ZIP, nix) and can assume neither —
// and because this runs in the daemon, whose launchd PATH names nothing anybody
// installed.
//
// `source` is what `~/.config/trill/rules.json` matches on, so "stop telling me
// about X" is a rule the user writes rather than a switch we'd have had to
// ship. Each caller passes its own: `pounce.update`, `pounce.url`.
enum Banner {
    /// Draw one. Returns immediately: the whole thing happens off the calling
    /// thread.
    ///
    /// OFF the main thread, and that is not tidiness. Callers raise banners
    /// from the main queue (the update check's timer, the URL door's Apple
    /// Event handler), and unlike a fire-and-forget osascript this has to WAIT
    /// for trill to answer before it knows whether to fall back. `trill send`
    /// reads its reply with no clock of its own, so a trill daemon that accepts
    /// the connection and then wedges would block pounce's runloop forever —
    /// ⌘Space dead until pounce is restarted. Nothing in either arm touches
    /// AppKit; both are child processes.
    static func post(title: String, body: String, source: String, symbol: String) {
        DispatchQueue.global(qos: .utility).async {
            if trillDrew(title: title, body: body, source: source, symbol: symbol) { return }
            fallback(title: title, body: body)
        }
    }

    /// The same banner, drawn on the calling thread, for a process about to
    /// exit: `post` would hand it to a queue that dies with the process before
    /// trill has been asked. Only for a caller with no runloop to protect —
    /// AppLaunchMode's last word on a link it could not deliver — never the
    /// daemon.
    static func postAndWait(title: String, body: String, source: String, symbol: String) {
        if trillDrew(title: title, body: body, source: source, symbol: symbol) { return }
        fallback(title: title, body: body)
    }

    /// True when trill took the event. False means "draw it some other way" —
    /// no Trill.app, no daemon (exit 2), or a send that never came back.
    ///
    /// The deadline is the point: a compositor that stopped answering must
    /// cost this check a few seconds and a fallback banner, never a hang. It
    /// terminates the child rather than just giving up on it, because the read
    /// blocks on a pipe that stays open as long as the process lives.
    private static func trillDrew(title: String, body: String,
                                  source: String, symbol: String) -> Bool {
        guard let trill = trillBinary() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: trill)
        p.arguments = ["send", "--source", source, "--kind", "note",
                       "--symbol", symbol,
                       "--title", title, "--body", body]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }

        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
        p.waitUntilExit()
        deadline.cancel()
        // Read only after waiting: `terminationStatus` on a live process
        // raises an ObjC exception no Swift `catch` can take.
        //
        // Exit 0 means the daemon ACCEPTED it, which is not the same as drew
        // it — a rule, a digest or quiet hours can route it elsewhere, and
        // that is the user's call, not something to second-guess with a
        // second banner through Apple.
        return p.terminationStatus == 0
    }

    /// Apple's banner, for a Mac with no trill.
    ///
    /// Both strings cross as `argv` and neither is interpolated into the
    /// script. That is a rule and not a precaution: a banner body can carry
    /// text somebody else wrote — the item key out of a `pounce://` link is the
    /// live example — and an interpolated quote in AppleScript is a syntax
    /// error at best and another statement at worst. The command scripts'
    /// `notify()` passes `on run argv` for the same reason.
    private static func fallback(title: String, body: String) {
        let script = """
        on run argv
          display notification (item 2 of argv) with title (item 1 of argv)
        end run
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script, title, body]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Trill.app, wherever it was installed, or nil. `$TRILL_APP` first so a
    /// branch build can be pointed at; then the two places every install source
    /// puts a bundle. Deliberately not `trill` on PATH: no install source
    /// reliably provides one, and the daemon's PATH would not see it if it did.
    private static func trillBinary() -> String? {
        var roots: [String] = []
        if let override = ProcessInfo.processInfo.environment["TRILL_APP"], !override.isEmpty {
            roots.append(override)
        }
        roots.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Trill.app").path)
        roots.append("/Applications/Trill.app")
        for root in roots {
            let binary = root + "/Contents/MacOS/Trill"
            if FileManager.default.isExecutableFile(atPath: binary) { return binary }
        }
        return nil
    }
}
