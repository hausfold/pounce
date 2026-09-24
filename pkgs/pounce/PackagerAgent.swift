import Foundation

// MARK: - Packager launch agents (read-only probe)
//
// A packager — haus's `com.hausfold.pounce`, or Homebrew's
// `homebrew.mxcl.pounce` from `brew services` — owns the daemon's lifecycle and
// the environment it runs in (haus exports POUNCE_EXTRA_COMMAND_DIRS,
// POUNCE_BUILTIN_DIR and HAUS_*; that is where haus's palette commands come
// from). Those agents are defined in haus's modules/launcher and the formula's
// service block, never here (AGENTS.md). This file only ASKS launchd whether
// one is loaded, so AppLaunchMode (LoginItem.swift) can defer to it instead of
// registering its own SMAppService job — which would win the socket at the
// next login and run the daemon without the packager's environment.
//
// Foundation-only, so the decision is pinned by tests/packager_tests.swift.

enum PackagerAgent {
    // Order is precedence when (unusually) both are loaded: haus's agent is the
    // one carrying the environment a haus machine's commands depend on.
    static let labels = ["com.hausfold.pounce", "homebrew.mxcl.pounce"]

    static var domain: String { "gui/\(getuid())" }

    // The first packager label launchd knows in this user's GUI domain, or nil
    // on a drag-install. `launchctl print` exits 0 for a loaded job whether or
    // not it is running right now — the loaded job is what will own the socket.
    static func loaded(isLoaded: (String) -> Bool = launchctlKnows) -> String? {
        labels.first(where: isLoaded)
    }

    static func launchctlKnows(_ label: String) -> Bool {
        launchctl(["print", "\(domain)/\(label)"]) == 0
    }

    // Without -k: a job that is already running (haus's wrapper can be sitting
    // in its guiWait) is left alone rather than restarted under us.
    @discardableResult
    static func kickstart(_ label: String) -> Bool {
        launchctl(["kickstart", "\(domain)/\(label)"]) == 0
    }

    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// What a no-argument Launch Services start does, as a pure decision so both
// arms — packager present and drag-install — are testable without launchd.
enum AppLaunchPlan: Equatable {
    case summon                 // daemon already up: show the palette
    case deferTo(String)        // a packager owns the daemon: kickstart it, never register
    case register               // no packager: self-register via SMAppService

    static func decide(daemonAlive: Bool, packager: String?) -> AppLaunchPlan {
        if daemonAlive { return .summon }
        if let packager { return .deferTo(packager) }
        return .register
    }
}
