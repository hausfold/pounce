import AppKit
import ServiceManagement

// MARK: - Login item (self-managed launchd agent) + the Finder-launch path
//
// This is what makes a Pounce.app dragged straight from the release download to
// /Applications a COMPLETE install: double-click it once and the daemon is
// running, ⌘Space works, and it comes back at every login — no Homebrew, no
// terminal, no Nix.
//
// Boundary note (see AGENTS.md): the launch agent for the RICE lives in
// nebelhaus/modules/pounce, and Homebrew's in the formula's service block —
// those are packager concerns and stay out of this repo. What lives HERE is the
// app registering ITSELF via SMAppService, the same in-process exception the
// global hotkey already has: a capability only the app can provide, needed
// exactly when there is no packager. The rice and brew never hit this path —
// they exec the binary with --daemon, which skips AppLaunchMode entirely.
//
// The agent is the plist build.sh bakes into
// Contents/Library/LaunchAgents/com.local.pounce.daemon.plist (the only
// location SMAppService.agent accepts). An SMAppService agent — unlike
// SMAppService.mainApp — passes explicit arguments, so the login launch is
// `pounce --daemon`, indistinguishable from the packagers' invocations. Its
// KeepAlive is {SuccessfulExit = false}: a crash restarts the daemon, but the
// single-instance guard's clean exit(0) (say, brew services already owns the
// socket) does NOT spin launchd in a relaunch/throttle loop.

enum Autostart {
    // Must match the plist filename build.sh writes into the bundle.
    static let plistName = "com.local.pounce.daemon.plist"

    @available(macOS 13.0, *)
    private static var service: SMAppService { .agent(plistName: plistName) }

    // Human-readable status for `pounce autostart status` and the doctor-style
    // logs. Distinguishes "needs the user's blessing in System Settings"
    // (.requiresApproval) from plain off, because that state looks identical to
    // a bug from the outside.
    static func statusDescription() -> String {
        guard #available(macOS 13.0, *) else { return "unavailable (needs macOS 13+)" }
        switch service.status {
        case .enabled:          return "on"
        case .requiresApproval: return "waiting for approval — System Settings → General → Login Items"
        case .notFound:         return "off (never registered)"
        case .notRegistered:    return "off"
        @unknown default:       return "unknown"
        }
    }

    static func isEnabled() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        return service.status == .enabled
    }

    // Registers the agent; launchd starts the daemon right away (RunAtLoad) and
    // at every login from then on. Throws through SMAppService's errors —
    // .requiresApproval surfaces as a throw too, and macOS shows the "added a
    // Login Item" notice so the user knows where the switch lives.
    static func register() throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(domain: "pounce", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "autostart needs macOS 13+ — use a launchd agent or brew services instead",
            ])
        }
        try service.register()
    }

    static func unregister() throws {
        guard #available(macOS 13.0, *) else { return }
        try service.unregister()
    }

    // `pounce autostart on|off|status` — positional like `focus` and `doctor`,
    // so an older binary that predates the verb never mistakes it for a picker
    // invocation (scripts probe `pounce --help` before calling).
    static func run(op: String?) {
        switch op {
        case "on":
            do {
                try register()
                print("autostart: \(statusDescription())")
            } catch {
                print("autostart: registration failed — \(error.localizedDescription)")
                print("           if macOS is asking for approval: System Settings → General → Login Items")
                exit(1)
            }
        case "off":
            do {
                try unregister()
                print("autostart: off")
            } catch {
                print("autostart: unregister failed — \(error.localizedDescription)")
                exit(1)
            }
        case "status":
            print("autostart: \(statusDescription())")
        default:
            print("usage: pounce autostart on|off|status")
            exit(2)
        }
    }
}

// The Finder double-click / login-item path: Launch Services starts the bundle
// executable with no arguments and launchd (pid 1) as the parent — a signature
// no CLI use shares (a terminal invocation's parent is the shell, and every
// packager's agent passes --daemon). Entry.swift routes that signature here.
//
// The flow is self-healing across every state the app can be found in:
//
//   daemon already running   → summon the launcher palette. Double-clicking a
//                              running app should show it, not error.
//   fresh drag-install       → register autostart (macOS notifies), wait for
//                              launchd to boot the daemon, then summon the
//                              palette as the first-run "it works" moment.
//   registration impossible  → (macOS 12, approval pending, SMAppService
//                              hiccup) run the daemon in-process so the app
//                              still works THIS session; login persistence
//                              catches up when the user approves.
enum AppLaunchMode {
    // The greeting: what a double-click shows when the daemon is (or has just
    // come) up — the launcher palette, same as ⌘Space.
    private static func summonLauncher() -> Never {
        var inv = Invocation()
        inv.launcher = true
        ClientMode.run(inv)
        exit(0)
    }

    static func run() {
        if SocketConfig.daemonAlive() {
            summonLauncher()
        }

        var registered = false
        do {
            try Autostart.register()
            registered = true
            NSLog("pounce: registered login item (\(Autostart.statusDescription()))")
        } catch {
            NSLog("pounce: login-item registration unavailable (\(error.localizedDescription)) — running daemon in-process")
        }

        // launchd's RunAtLoad boot isn't instant; give it a moment before
        // concluding we must host the daemon ourselves.
        if registered {
            for _ in 0..<20 where !SocketConfig.daemonAlive() {
                usleep(150_000)   // 20 × 150ms = 3s ceiling, exits early once alive
            }
            if SocketConfig.daemonAlive() {
                summonLauncher()
            }
            NSLog("pounce: login item registered but the daemon isn't up yet — running it in-process")
        }

        // In-process fallback. The single-instance guard in DaemonMode.run()
        // makes this safe even if launchd's copy arrives late: whichever loses
        // the socket race exits 0 and stays exited.
        DaemonMode.run()
    }
}
