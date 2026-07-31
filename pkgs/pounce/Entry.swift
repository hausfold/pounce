import SwiftUI
import AppKit
import ApplicationServices
import CoreServices

// MARK: - Entry Point

@main
enum Main {
    static let usage = """
    pounce — summon, aim, pounce. A scriptable command palette for macOS.

    usage:
      pounce [-p <prompt>] [-i <sf-symbol>] [--max-empty <n>] [--chain]
        generic picker: reads lines from stdin, prints the chosen one
        --chain: Enter on typed text feeds another pounce step — hold the
        window up with the loading skeleton instead of fading out

    modes:
      --launcher             apps + commands palette (what the hotkey opens)
      --cheatsheet [path]    cheatsheet overlay (default ~/.config/pounce/cheatsheet.json)

    running one item:
      run <item-key>            run a single item by the key config.json's
                                `items` map uses — `cmd:emoji`,
                                `mode:clipboard`, `app:/Applications/Foo.app`.
                                For binders that already own the keystroke
                                (AeroSpace binding modes, skhd, Shortcuts):
                                they do the chord, pounce does the action.

                                The built-in windows live here:
                                  mode:clipboard      clipboard history
                                  mode:emoji          emoji picker
                                  mode:screenshots    screenshot browser
                                  mode:camera         camera preview
                                  mode:filesearch     file/folder search
                                  mode:launcher       the palette itself

    diagnostics:
      doctor                    check the hotkey path — is the daemon up, is the
                                in-process hotkey actually firing, or is an
                                external tool (skhd/AeroSpace/Raycast) or a macOS
                                shortcut shadowing it

    focus (hush):
      focus status              print on/off from the DoNotDisturb DB
      focus toggle              press the DND symbolic-hotkey chord
      focus on|off              deterministic: read, press only if needed, verify
                                the grants (Accessibility + Full Disk Access) live on
                                the signed Pounce.app; a caller without them forwards
                                the op to the running daemon automatically

    selection:
      --transform <filter>      act on the current selection: copy it (⌘C), pipe
                                the text through the shell <filter>, paste back
                                (⌘V). e.g. --transform 'tr "[:lower:]" "[:upper:]"'.
                                Forwarded to the daemon, which holds the grant.

    housekeeping:
      --daemon                  run the resident daemon (launchd uses this; also
                                hosts the MRU window switcher when config.json
                                sets windows.enabled — see the README)
      autostart on|off|status   start the daemon at login via a self-registered
                                login item (System Settings → Login Items).
                                For drag-installs of Pounce.app; Homebrew users
                                use `brew services`, the nebelhaus rice wires
                                its own agent. Double-clicking Pounce.app
                                registers this automatically.
      --copy-file <path>        copy a file to the clipboard and exit
      --request-accessibility   prompt for the Accessibility (TCC) grant
      --check-accessibility     print true/false for the grant
      --request-bluetooth       prompt for the Bluetooth (TCC) grant
      --check-bluetooth         print true/false for the grant
      --version                 print the version
      -h, --help                this text

    config: ~/.config/pounce/config.json   commands: ~/.config/pounce/commands
    docs:   https://nebelhaus.com/reference/pounce/
    """

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            print(usage)
        } else if args.contains("--version") {
            // pounceVersion comes from Version.generated.swift (see build.sh).
            print("pounce \(pounceVersion)")
        } else if args.count >= 2 && args[1] == "doctor" {
            // Positional, like `focus`: a health check for the hotkey path that
            // never opens the palette.
            DoctorMode.run()
        } else if args.count >= 2 && args[1] == "run" {
            // Positional, like `doctor` and `focus`: run one item by its key
            // ("cmd:emoji", "mode:clipboard", "app:/Applications/Foo.app").
            // The escape hatch for anyone whose keystrokes are already owned by
            // an external binder — AeroSpace binding modes, skhd, a Shortcut —
            // so a two-step there can drive pounce without pounce owning a key.
            RunMode.run(target: args.count >= 3 ? args[2] : nil)
        } else if args.count >= 2 && args[1] == "focus" {
            // Positional on purpose: scripts probe `pounce --help` for
            // "focus" before calling, so an older binary never falls through
            // to ClientMode and opens the palette by accident.
            FocusMode.run(op: args.count >= 3 ? args[2] : nil)
        } else if let i = args.firstIndex(of: "--copy-file"), i + 1 < args.count {
            CopyFileMode.run(path: args[i + 1])
        } else if let i = args.firstIndex(of: "--transform"), i + 1 < args.count {
            // Act on the current selection: ⌘C → pipe through the shell filter
            // → ⌘V. Forwarded to the daemon (which holds Accessibility) like
            // `focus`. See Transform.swift.
            TransformMode.run(filter: args[i + 1])
        } else if args.contains("--check-accessibility") {
            // Silent trust check for scripted verification. AXIsProcessTrusted
            // reflects THIS binary's code identity, so run it from the signed copy
            // to confirm the daemon's identity holds the grant.
            print(AXIsProcessTrusted() ? "true" : "false")
        } else if args.contains("--request-accessibility") {
            // One-shot bootstrap: fire the system "add to Accessibility" prompt.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            print(AXIsProcessTrustedWithOptions(opts) ? "true" : "false")
        } else if args.contains("--check-bluetooth") {
            print(BluetoothGrant.check() ? "true" : "false")
        } else if args.contains("--request-bluetooth") {
            // One-shot bootstrap: fire the system Bluetooth prompt (see
            // BluetoothGrant.swift for why blueutil can't do this itself).
            BluetoothGrant.request()
        } else if args.count >= 2 && args[1] == "autostart" {
            // Positional like `focus`/`doctor` (see those branches for why).
            // Manages the self-registered login item — the drag-install
            // counterpart of `brew services start pounce` (LoginItem.swift).
            Autostart.run(op: args.count >= 3 ? args[2] : nil)
        } else if args.contains("--daemon") {
            DaemonMode.run()
        } else if args.count == 1 && getppid() == 1 {
            // No arguments AND launchd is the parent: this is Launch Services
            // starting the app — a Finder double-click, `open Pounce.app`, or a
            // login item — not a CLI use (a terminal invocation's parent is the
            // shell, pipes included, and every packager's agent passes
            // --daemon). Without this branch a double-click of the downloaded
            // app fell into ClientMode: an empty stdin picker, the worst
            // possible first run. See LoginItem.swift for the flow.
            AppLaunchMode.run()
        } else {
            ClientMode.run()
        }
    }
}

// `pounce run <item-key>`: execute one item by the same key config.json's
// `items` map is addressed with. Forwarded to the daemon so it runs through the
// identical path a hotkey takes (DaemonMode.runTargetHook) — one implementation
// of the target grammar regardless of what pressed the key.
//
// The point is composability with tools that already own the keyboard: a
// nebelhaus user's AeroSpace binding mode, skhd, a Shortcut, a Stream Deck. They
// do the two-step; pounce just executes step two.
enum RunMode {
    static func run(target: String?) {
        guard let target, !target.isEmpty else {
            FileHandle.standardError.write(Data("""
            pounce run: needs an item key.
              pounce run cmd:emoji                       a command script
              pounce run mode:clipboard                  a built-in window
              pounce run app:/Applications/Ghostty.app   an application
            \n
            """.utf8))
            exit(2)
        }
        // A "mode:" target has to be the daemon: only it owns the window. A
        // cmd:/app: target could be done here, but routing everything through
        // the daemon keeps command resolution identical to the hotkey path
        // (same command dirs, same shadowing order).
        guard let reply = Daemon.request("RUN\t\(target)\n") else {
            FileHandle.standardError.write(Data(
                "pounce run: daemon not running (start it: `brew services start pounce`)\n".utf8))
            exit(1)
        }
        if reply.hasPrefix("err") {
            let detail = reply.split(separator: "\t").dropFirst().joined(separator: " ")
            FileHandle.standardError.write(Data("pounce run: \(detail)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}

// `pounce --copy-file <path>`: copy a file to the clipboard as both image and
// file reference (see Pasteboard.copyFile) and exit. Synchronous — no run loop.
enum CopyFileMode {
    static func run(path: String) {
        Pasteboard.copyFile(URL(fileURLWithPath: path))
        exit(0)
    }
}

// MARK: - Argument / Config Parsing

// What a CLIENT invocation carries. The five built-in windows that used to have
// a flag each here (--clipboard, --emoji, --screenshots, --camera, --find-files)
// are reached as `pounce run mode:<name>` now: one grammar for "do this item",
// whether the trigger is a Carbon hotkey, a leader sequence, a palette row or an
// external binder. What's left is the two invocations that AREN'T an item —
// a stdin-fed picker (optionally --launcher, which merges installed apps into the
// list) and the cheatsheet overlay, which takes a path.
struct Invocation {
    var placeholder: String?
    var icon: String?
    var launcher = false
    var cheatsheet = false
    var cheatsheetPath = "~/.config/pounce/cheatsheet.json"
    var maxEmpty: Int?
    // The caller's next act, after Enter on typed text, is another `pounce`
    // invocation — so the window should hold the loading skeleton rather than
    // fade out and re-open. Only the free-text commit is affected: picking a
    // row still lingers, because a row's follow-up may be a terminal action.
    var chain = false
}

// MARK: - Daemon Mode

enum DaemonMode {
    // Retained for the daemon's lifetime so its Carbon handler stays installed.
    static var hotKey: HotKeyManager?
    // Retained so the ⌘Tab event tap + window tracker stay alive.
    static var windowSwitcher: WindowSwitcher?
    // Retained for the daemon's lifetime so an armed leader's transient
    // registrations and timers survive (see Leader.swift).
    static var leader: LeaderRunner?
    // The one implementation of the target grammar ("cmd:emoji", "mode:clipboard"),
    // set by run() so `pounce run <target>` over the socket dispatches exactly
    // as a hotkey does. nil until the daemon is up.
    static var runTargetHook: ((String) -> Void)?
    // Last Accessibility trust state we logged, so the watcher only emits on a
    // change. Seeded by the startup log line below.
    static var lastTrusted: Bool?
    static var accessibilityTimer: Timer?

    // Hotkey lifecycle, exposed for `pounce doctor` (see DoctorMode) and the
    // shadow-hint below. `registered` = Carbon accepted it; `received` = it has
    // actually fired at least once. The two diverge exactly when an external
    // hotkey daemon (skhd/AeroSpace/Raycast) or a system shortcut swallows the
    // key — the footgun `doctor` exists to name.
    static var hotkeyEnabled = false
    static var hotkeyCombo = ""
    static var hotkeyRegistered = false
    static var hotkeyReceived = false
    // Per-item bindings from config.json's `items` map, as human-readable lines
    // ("⌥E → cmd:emoji" / "… — FAILED (taken?)"). Reported over the socket to
    // `pounce doctor`: a binding that lost its combo to another app fails
    // silently from the user's side, so the daemon has to be able to say so.
    static var bindingReport: [String] = []
    // One-time guard for the "external client while the hotkey never fired" hint.
    static var shadowHintLogged = false

    // Arms the MRU window switcher (⌘Tab tap) if it's configured, permitted, and
    // not already up. Idempotent, so it's safe to call both at startup and again
    // from the accessibility watcher whenever the grant flips on — a grant ticked
    // *after* the daemon booted then activates ⌘Tab live, no restart needed (the
    // event tap needs Accessibility, which the user may only grant later).
    static func armWindowSwitcher(_ settings: WindowSwitcherSettings) {
        guard settings.enabled, windowSwitcher == nil else { return }
        let combo = "\(settings.modifiers.joined(separator: "+"))+\(settings.key)"
        guard AXIsProcessTrusted() else {
            NSLog("pounce daemon: windows.enabled is set but Accessibility is not granted; window switcher off, stock \(combo) untouched (grant via `pounce --request-accessibility`)")
            return
        }
        if let switcher = WindowSwitcher(settings: settings) {
            windowSwitcher = switcher
            NSLog("pounce daemon: window switcher armed on \(combo)")
        } else {
            NSLog("pounce daemon: window switcher event tap failed to install; stock \(combo) untouched")
        }
    }

    // The startup `trusted=` line is a snapshot: TCC can flip while the daemon
    // runs (the user ticks the box in System Settings, or a `brew upgrade`
    // reissues the adhoc signature and drops the grant). AXIsProcessTrusted() is
    // live at every point of use, but a stale one-time log misleads anyone
    // reading it — so poll and log the transitions, giving the log a truthful
    // running account of the grant instead of a frozen boot-time value.
    //
    // The watcher also acts on the flip: on grant it arms the ⌘Tab switcher whose
    // tap couldn't install without Accessibility (so no daemon restart is needed);
    // on revoke it drops the now-dead tap so the stock switcher resumes and a
    // later re-grant re-arms from a clean slate.
    static func watchAccessibility(windows: WindowSwitcherSettings) {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let now = AXIsProcessTrusted()
            if now != lastTrusted {
                lastTrusted = now
                NSLog("pounce daemon accessibility trusted=\(now) (changed while running)")
                if now {
                    armWindowSwitcher(windows)
                } else if windowSwitcher != nil {
                    windowSwitcher = nil   // deinit disables the tap + removes the run-loop source
                    NSLog("pounce daemon: Accessibility revoked; window switcher disarmed, stock switcher restored")
                }
            }
        }
    }

    static func run() {
        // Single-instance guard. Two supervisors can legitimately race for the
        // daemon — brew services and the self-registered login item, or launchd's
        // copy arriving while AppLaunchMode's in-process fallback is booting —
        // and startSocketServer would otherwise silently STEAL the socket from
        // the incumbent, leaving two daemons fighting over one hotkey. The loser
        // exits 0 on purpose: the login agent's KeepAlive only restarts on
        // non-zero exits, so a clean "already running" never spins launchd.
        if SocketConfig.daemonAlive() {
            NSLog("pounce daemon: another daemon already owns \(SocketConfig.path) — exiting")
            exit(0)
        }

        // Homebrew and the rice run the executable inside Pounce.app directly
        // rather than opening the bundle through Launch Services. Register it
        // explicitly so Background Items can resolve the launch-agent
        // AssociatedBundleIdentifiers entry to "Pounce" instead of falling back
        // to the Developer ID certificate owner.
        let lsStatus = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        if lsStatus != noErr {
            NSLog("pounce: Launch Services registration failed (status \(lsStatus))")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let state = DaemonState()
        let ui = PounceUI(state: state)
        ui.window.orderOut(nil)
        // Warm the SwiftUI render pipeline off the hot path so the first ⌘Space
        // doesn't pay NSHostingView's initial layout/draw on the keystroke.
        DispatchQueue.main.async { ui.warmRender() }

        AppScanner.shared.warm()
        EmojiStore.shared.warm()   // filter the dataset to OS-renderable glyphs off the main thread

        // Warm the command registry so the first ⌘Space doesn't pay the initial
        // scan + header parse. Kept on the main queue — refresh() is only ever
        // touched from the main thread (here and in presentLauncher), so the
        // registry needs no locking.
        let registry = CommandRegistry()
        DispatchQueue.main.async { registry.refresh() }

        let settings = Settings.load()

        // Currency rates for the quick-answer engine: hydrate from the disk
        // cache now, refresh from the network when stale, re-check every 6h.
        // Keystrokes only ever read the warmed in-memory table.
        if settings.quickAnswers.currency {
            CurrencyRates.shared.warm()
            Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
                CurrencyRates.shared.warm()
            }
        }

        // Update nudge: same warm-on-a-timer shape as the rates, but hourly —
        // a release should surface the day it's cut, not up to a day later.
        // maxAge inside warm() keeps that a re-check rather than a re-fetch,
        // and the banner it may raise is separately rate-limited to daily.
        // Every install kind is nudged (the copy names each one's own command,
        // per InstallKind); only `updates.check` and dev builds opt out.
        if settings.updates.check {
            UpdateNudge.shared.warm()
            Timer.scheduledTimer(withTimeInterval: UpdateNudge.maxAge, repeats: true) { _ in
                UpdateNudge.shared.warm()
            }
        }

        // The in-process launcher: what ⌘Space triggers. No shell, no client, no
        // socket — build the launcher from the cached registry + warm app list and
        // present the already-built window straight away. Toggling: a second press
        // while it's up dismisses it (Raycast-style).
        // The startup log says the key was *registered*; hotkeyReceived says it's
        // actually *received* — the two diverge exactly when a system shortcut
        // (Spotlight ⌘Space) or a third-party launcher swallows the key, the
        // failure that leaves the present log empty despite the user mashing
        // ⌘Space. Logged once; also read by `pounce doctor`.
        let presentLauncher: () -> Void = {
            if !hotkeyReceived {
                hotkeyReceived = true
                NSLog("pounce daemon: hotkey received its first press — the in-process launcher path is live")
            }
            if state.isVisible { state.cancel(); return }
            let t0 = DispatchTime.now()
            let settings = Settings.load()   // re-read so config edits apply live
            Theme.current = settings.palette
            state.reset()
            state.metrics = settings.metrics
            registry.refresh()
            // A pending update renames the Update Pounce row in place (see
            // UpdateCheck.swift) — the nudge lives exactly where the fix is.
            let lines = registry.entries.map {
                (UpdateNudge.shared.decorate($0) ?? $0).registryLine
            }
            state.load(lines: lines, placeholder: "Search apps & actions...",
                       icon: "magnifyingglass", launcher: true, maxEmpty: 7)
            let tBuild = DispatchTime.now()   // registry + app scan + frecency + sort
            // Launcher selections that aren't native app launches arrive as
            // "run\t<id>"; spawn that command script ourselves, the way
            // pounce-palette used to exec it. App launches come back with an empty
            // string (handled natively in PounceUI) and are ignored here.
            ui.resultSink = { result in
                guard result.hasPrefix("run\t") else { return }
                let id = String(result.dropFirst(4))
                if let path = registry.scriptPath(for: id) { CommandSpawner.run(scriptPath: path) }
            }
            ui.present()
            // Press→present latency on the in-process fast path, broken into
            // phases so a summon-lag report localizes the cost instead of guessing:
            //   build   — synchronous registry refresh + app scan + sort
            //   sync    — build + present()'s synchronous layout/activate
            //   visible — build + sync + the deferred reveal tick (resize + fade
            //             in). This last runloop turn is NOT counted by the first
            //             two, yet it's where SwiftUI paints and the compositor
            //             shows the window — so on a machine where `sync` is small
            //             but the summon still feels slow, `visible` is the tell.
            // All three carry the "launcher present" substring so one grep catches
            // them. If these lines appear on the user's hotkey they're on the fast
            // daemon path (not an external binder spawning pounce-palette).
            let ms = { (t: DispatchTime) in
                Int((Double(DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000).rounded())
            }
            let buildMs = ms(t0) - ms(tBuild)
            let syncMs = ms(t0)
            let count = state.items.count
            DispatchQueue.main.async {
                NSLog("pounce daemon: launcher present — build \(buildMs)ms, sync \(syncMs)ms, visible \(ms(t0))ms (\(count) items)")
            }
        }

        // Open a built-in window (clipboard, emoji, …) directly, the way a
        // per-item "mode:" binding asks for. Mirrors what handleClient does for
        // the same request arriving over the socket — release any waiting
        // client, re-read settings, load the mode, present — minus the round
        // trip. Pressing the same binding again while that mode is up dismisses
        // it, matching the palette hotkey's toggle.
        let presentMode: (DisplayMode, (DaemonState) -> Void) -> Void = { mode, load in
            if state.isVisible && state.displayMode == mode { state.cancel(); return }
            ui.resultSink?("")
            ui.resultSink = nil
            let settings = Settings.load()
            Theme.current = settings.palette
            state.reset()
            state.metrics = settings.metrics
            load(state)
            ui.present()
        }

        // Run whatever a binding's target names. The target grammar is the same
        // one that keys config.json's `items` map (see ItemSetting), so a
        // settings UI writes one string and it works as both a row key and a
        // hotkey target. Unknown targets are logged, not silently dropped —
        // a typo'd command id would otherwise present as a dead key.
        let runTarget: (String) -> Void = { target in
            switch ItemTarget.parse(target) {
            case .mode("launcher"):
                presentLauncher()
            case .mode("clipboard"):   presentMode(.clipboard) { $0.loadClipboard(placeholder: nil) }
            case .mode("emoji"):       presentMode(.emoji) { $0.loadEmoji(placeholder: nil) }
            case .mode("screenshots"): presentMode(.screenshots) { $0.loadScreenshots(placeholder: nil) }
            case .mode("camera"):      presentMode(.camera) { $0.loadCamera(placeholder: nil) }
            case .mode("filesearch"):  presentMode(.fileSearch) { $0.loadFileSearch(placeholder: nil) }
            case .mode(let name):
                // Unreachable: ItemTarget.parse only yields modes it knows.
                NSLog("pounce daemon: built-in mode '\(name)' has no dispatch case")
            case .command(let id):
                registry.refresh()
                if let path = registry.scriptPath(for: id) {
                    CommandSpawner.run(scriptPath: path)
                } else {
                    NSLog("pounce daemon: target '\(target)' names no known command; check the script exists in a command dir")
                }
            case .app(let path):
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg)
            case nil:
                NSLog("pounce daemon: \(ItemTarget.problem(with: target) ?? "bad target '\(target)'"); ignored")
            }
        }
        // Published so `pounce run <target>` arriving over the socket executes
        // through the exact same path a hotkey does — one implementation of the
        // target grammar, whether the trigger is Carbon or an external binder
        // (AeroSpace, skhd) that already owns the keystroke.
        runTargetHook = runTarget

        hotkeyEnabled = settings.hotkey.enabled
        hotkeyCombo = "\(settings.hotkey.modifiers.joined(separator: "+"))+\(settings.hotkey.key)"
        // One manager holds the palette key and every per-item binding.
        let manager = HotKeyManager()
        hotKey = manager
        if settings.hotkey.enabled {
            if let keyCode = HotKeyParser.keyCode(for: settings.hotkey.key) {
                let modifiers = HotKeyParser.modifierMask(for: settings.hotkey.modifiers)
                if manager.register(keyCode: keyCode, modifiers: modifiers, onFire: presentLauncher) {
                    hotkeyRegistered = true
                    let combo = hotkeyCombo
                    NSLog("pounce daemon: hotkey \(combo) registered")
                    // Registration succeeding doesn't mean we'll get the key: if
                    // macOS still owns the same combo (Spotlight ⌘Space is the
                    // classic case), the system wins and pounce never receives a
                    // press. Name the conflict so the fix is obvious instead of
                    // the summon just silently doing nothing.
                    if let conflict = HotKeyConflict.systemConflict(keyName: settings.hotkey.key,
                                                                    modifierNames: settings.hotkey.modifiers) {
                        NSLog("pounce daemon: WARNING — \(combo) is also bound to \(conflict); macOS routes the key there, so pounce likely never receives it and the palette won't open. Disable that shortcut in System Settings → Keyboard → Keyboard Shortcuts, then restart pounce.")
                    }
                } else {
                    NSLog("pounce daemon: could not register hotkey \(settings.hotkey.modifiers.joined(separator: "+"))+\(settings.hotkey.key) (already taken?); falling back to socket launch")
                }
            } else {
                NSLog("pounce daemon: unknown hotkey key '\(settings.hotkey.key)'; falling back to socket launch")
            }
        }

        // Per-item hotkeys from config.json's `items` map: ⌥E straight to the
        // emoji picker, ⌘⇧V to clipboard history, a key per command or app.
        // Read once here, so adding or changing one needs a daemon restart
        // (`launchctl kickstart -k`) — same contract as `windows`, unlike the
        // palette settings which are re-read per open. Each binding is
        // independent: a combo another app already owns fails alone and is
        // named in the log, leaving the rest armed.
        // The warm-up refresh above is async, so the registry is still empty
        // here — resolve it now if any binding needs to be checked against it.
        // Repeating the scan is a few stats; the async warm-up then no-ops.
        if settings.items.bindings.contains(where: { $0.target.hasPrefix("cmd:") }) {
            registry.refresh()
        }

        // Does this target name a command that isn't there? Targets resolve at
        // FIRE time (a script can appear after the daemon starts), so a mistyped
        // id would otherwise register happily and only fail on the keypress —
        // the exact "I pressed it and nothing happened" report doctor exists to
        // pre-empt. Name it at startup instead, without refusing the binding.
        let namesMissingCommand: (String) -> Bool = { target in
            target.hasPrefix("cmd:") && registry.scriptPath(for: String(target.dropFirst(4))) == nil
        }

        // Leader sequences ("opt+space e") share a tree, so a leader shared by
        // several items is ONE registration owning a map of next steps. The
        // leader's own key is registered permanently; the second-step keys are
        // grabbed only while it's armed — that's what keeps this free of any
        // Accessibility grant (see Leader.swift).
        let (tree, conflicts) = HotKeyNode.build(settings.items.bindings)
        for conflict in conflicts {
            NSLog("pounce daemon: binding conflict — \(conflict)")
            bindingReport.append("conflict — \(conflict)")
        }
        let leaderRunner = LeaderRunner(
            onRun: { runTarget($0) },
            onHint: { node in
                // Which-key overlay, through the existing cheatsheet window.
                // Only reached if the user hesitates past LeaderRunner.hintDelay.
                let groups = LeaderHint.groups(for: node) { target in
                    guard target.hasPrefix("cmd:") else { return nil }
                    let id = String(target.dropFirst(4))
                    return registry.entries.first { $0.id == id }?.name
                }
                ui.resultSink?("")
                ui.resultSink = nil
                let settings = Settings.load()
                Theme.current = settings.palette
                state.reset()
                state.metrics = settings.metrics
                state.displayMode = .cheatsheet
                state.cheatsheetGroups = groups
                ui.present()
            },
            onDismissHint: { if state.displayMode == .cheatsheet { state.cancel() } })
        leader = leaderRunner

        // Register the first step of every distinct sequence. A leaf child of
        // the root is an ordinary one-step binding; anything with children of
        // its own is a leader that arms the runner instead of acting.
        for node in tree.sortedChildren {
            guard let step = node.step else { continue }
            // Every target reachable from here, for the log and doctor line.
            let reachable = HotKeyNode.targets(under: node)
            let label = node.isLeaf
                ? "\(step.display) → \(node.target!)"
                : "\(step.display) → leader (\(reachable.count) sequence\(reachable.count == 1 ? "" : "s"))"

            guard let keyCode = HotKeyParser.keyCode(for: step.key) else {
                NSLog("pounce daemon: binding \(label) uses unknown key '\(step.key)'; skipped")
                bindingReport.append("\(label) — unknown key '\(step.key)'")
                continue
            }
            let modifiers = HotKeyParser.modifierMask(for: step.modifiers)
            let fire: () -> Void = node.isLeaf
                ? { runTarget(node.target!) }
                : { leaderRunner.arm(node) }

            guard manager.register(keyCode: keyCode, modifiers: modifiers, onFire: fire) else {
                NSLog("pounce daemon: could not register binding \(label) (already taken by another app?)")
                bindingReport.append("\(label) — FAILED, combo already taken")
                continue
            }
            NSLog("pounce daemon: binding \(label) registered")

            // For a leader, confirm now that its second-step keys can actually
            // be grabbed. A bare key another app holds permanently would kill
            // just that branch, and only on the day you pressed it.
            if !node.isLeaf {
                let probe = leaderRunner.probe(node)
                if probe.failed.isEmpty {
                    NSLog("pounce daemon: leader \(step.display) — \(probe.grabbed)/\(probe.grabbed) next-step keys grabbable")
                } else {
                    NSLog("pounce daemon: WARNING — leader \(step.display) cannot grab \(probe.failed.joined(separator: ", ")); those branches won't fire (another app holds the key)")
                    bindingReport.append("\(label) — cannot grab next-step key: \(probe.failed.joined(separator: ", "))")
                    continue
                }
            }

            if let conflict = HotKeyConflict.systemConflict(keyName: step.key,
                                                            modifierNames: step.modifiers) {
                NSLog("pounce daemon: WARNING — \(step.display) is also bound to \(conflict); macOS routes the key there, so this binding likely never fires.")
                bindingReport.append("\(label) — also bound to \(conflict)")
                continue
            }
            let missing = reachable.filter(namesMissingCommand)
            if missing.isEmpty {
                bindingReport.append(label)
            } else {
                NSLog("pounce daemon: WARNING — binding \(label) reaches \(missing.joined(separator: ", ")), which name no command found in any command dir; those keys will do nothing until the scripts exist.")
                bindingReport.append("\(label) — no such command: \(missing.joined(separator: ", "))")
            }
        }

        // The MRU window switcher (default ⌘Tab, see Switcher.swift). Unlike the
        // palette hotkey (Carbon, no permissions), taking ⌘Tab needs an event
        // tap, which macOS gates behind Accessibility — without the grant the
        // stock switcher is left untouched, so enabling this can never brick
        // window switching. If the grant is only ticked later, watchAccessibility
        // arms it live, so this boot-time call may find no grant and no-op.
        armWindowSwitcher(settings.windows)

        // Clipboard history watcher: poll the pasteboard while the daemon lives.
        if settings.clipboard.enabled {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                ClipboardStore.shared.poll()
            }
        }

        let cleanupAndExit: @convention(c) (Int32) -> Void = { _ in
            unlink(SocketConfig.path); _exit(0)
        }
        signal(SIGTERM, cleanupAndExit)
        signal(SIGINT, cleanupAndExit)

        DispatchQueue.global(qos: .userInitiated).async {
            startSocketServer(state: state, ui: ui)
        }

        NSLog("pounce daemon started, listening on \(SocketConfig.path)")
        // Snapshot at boot; watchAccessibility() then logs any later transition
        // so the grant's true running state is always in the log, not just the
        // value that happened to hold the instant the daemon launched.
        lastTrusted = AXIsProcessTrusted()
        NSLog("pounce daemon accessibility trusted=\(lastTrusted!) (startup snapshot)")
        watchAccessibility(windows: settings.windows)
        app.run()
    }

    static func startSocketServer(state: DaemonState, ui: PounceUI) {
        unlink(SocketConfig.path)
        try? FileManager.default.createDirectory(atPath: SocketConfig.dir,
                                                 withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("pounce daemon: failed to create socket"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            SocketConfig.path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(strlen(cstr) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
        }) == 0 else { NSLog("pounce daemon: failed to bind socket"); close(fd); return }

        guard listen(fd, 5) == 0 else { NSLog("pounce daemon: failed to listen"); close(fd); return }

        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &clientLen) }
            }
            guard clientFD >= 0 else { continue }
            // One detached thread per connection so accept() is NEVER blocked. A
            // palette (CONFIG) request blocks its handler on semaphore.wait() for
            // the whole time the window is up; a palette that never dismisses —
            // e.g. under a tiling WM (AeroSpace) it may never become key, so
            // Esc/click-away never fire — would otherwise wedge this single accept
            // loop forever. Once wedged, the listen backlog fills and every later
            // connection (focus/status pings, `doctor`, and crucially new picker
            // opens) gets ECONNREFUSED. A built-in window then can't open at all:
            // `pounce run mode:clipboard` needs this socket, and reports the daemon
            // as unreachable rather than opening an untrusted client copy that could
            // copy to the pasteboard but never post the ⌘V (no Accessibility) —
            // "it copies but won't paste", which was the older, worse failure.
            // Handling each client off the accept loop keeps the daemon reachable so
            // pickers always route through it.
            Thread.detachNewThread { handleClient(clientFD: clientFD, state: state, ui: ui) }
        }
    }

    static func handleClient(clientFD: Int32, state: DaemonState, ui: PounceUI) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(clientFD, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let payload = String(data: data, encoding: .utf8), !payload.isEmpty else {
            close(clientFD); return
        }

        // `pounce doctor` asks the live daemon for its hotkey/accessibility state
        // over the socket (the daemon is the only one that knows whether the
        // in-process hotkey has actually fired). Reply one JSON line and hang up.
        if payload.hasPrefix("STATUS") {
            let status: [String: Any] = [
                "version": pounceVersion,
                "accessibility": AXIsProcessTrusted(),
                "hotkeyEnabled": DaemonMode.hotkeyEnabled,
                "hotkeyCombo": DaemonMode.hotkeyCombo,
                "hotkeyRegistered": DaemonMode.hotkeyRegistered,
                "hotkeyReceived": DaemonMode.hotkeyReceived,
                "bindings": DaemonMode.bindingReport,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: status)) ?? Data("{}".utf8)
            var reply = json; reply.append(0x0A)
            reply.withUnsafeBytes { ptr in _ = write(clientFD, ptr.baseAddress!, reply.count) }
            close(clientFD)
            return
        }

        // `pounce run <item-key>` arrives as "RUN\t<target>" and dispatches
        // through the SAME closure a hotkey fires (runTargetHook), so an
        // external binder that already owns the keystroke — an AeroSpace binding
        // mode, skhd, a Shortcut — gets identical behaviour to a native binding.
        // Hopped to the main queue because the target may present a window;
        // acknowledged immediately rather than waiting on that window to close.
        if payload.hasPrefix("RUN\t") {
            let target = String(payload.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            let reply: String
            // Reject a malformed target BEFORE acknowledging: dispatch is
            // fire-and-forget on the main queue, so without this a typo'd target
            // would exit 0 and look like it worked.
            if let problem = ItemTarget.problem(with: target) {
                reply = "err\t\(problem)"
            } else if let run = DaemonMode.runTargetHook {
                DispatchQueue.main.async { run(target) }
                reply = "ok"
            } else {
                reply = "err\tdaemon has no target dispatcher (not fully started?)"
            }
            let replyData = Data((reply + "\n").utf8)
            replyData.withUnsafeBytes { ptr in _ = write(clientFD, ptr.baseAddress!, replyData.count) }
            close(clientFD)
            return
        }

        // Focus ops arrive as their own one-line protocol ("FOCUS\t<op>") and
        // run HERE, under the daemon's own TCC identity — the whole point:
        // `pounce focus` spawned by the bar pill or a terminal is attributed
        // to THAT app and holds no grants (Focus.swift). No UI, no main-thread
        // hop; reply one line and hang up.
        if payload.hasPrefix("FOCUS\t") {
            let op = payload.dropFirst("FOCUS\t".count).trimmingCharacters(in: .whitespacesAndNewlines)
            let r = FocusMode.perform(op)
            let reply = r.code == 0 ? (r.out.isEmpty ? "ok" : r.out) : "err\t\(r.code)\t\(r.err)"
            let replyData = (reply + "\n").data(using: .utf8)!
            replyData.withUnsafeBytes { ptr in _ = write(clientFD, ptr.baseAddress!, replyData.count) }
            close(clientFD)
            return
        }

        // Transform-selection ops arrive as "TRANSFORM\t<shell filter>" and,
        // like FOCUS, run HERE under the daemon's own TCC identity (only the
        // signed daemon holds the Accessibility grant that lets ⌘C/⌘V post).
        // No UI, no main-thread hop — every step in perform() is thread-safe;
        // reply one line and hang up. The palette window is already hidden and
        // focus handed back to the source app by the time this fires.
        if payload.hasPrefix("TRANSFORM\t") {
            let filter = String(payload.dropFirst("TRANSFORM\t".count)).trimmingCharacters(in: .newlines)
            let r = TransformMode.perform(filter: filter)
            let reply = r.code == 0 ? "ok" : "err\t\(r.code)\t\(r.err)"
            let replyData = (reply + "\n").data(using: .utf8)!
            replyData.withUnsafeBytes { ptr in _ = write(clientFD, ptr.baseAddress!, replyData.count) }
            close(clientFD)
            return
        }

        var lines = payload.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var inv = Invocation()
        var itemLines: [String] = lines
        if let first = lines.first, first.hasPrefix("CONFIG\t") {
            let p = first.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if p.count > 1 && !p[1].isEmpty { inv.placeholder = p[1] }
            if p.count > 2 && !p[2].isEmpty { inv.icon = p[2] }
            if p.count > 3 && p[3] == "launcher" { inv.launcher = true }
            if p.count > 3 && p[3] == "cheatsheet" { inv.cheatsheet = true }
            if p.count > 4, let m = Int(p[4]) { inv.maxEmpty = m }
            if p.count > 5 && !p[5].isEmpty { inv.cheatsheetPath = p[5] }
            if p.count > 6 && p[6] == "1" { inv.chain = true }
            itemLines = Array(lines.dropFirst())
        }

        // Passive shadow-hint: a launcher request came in over the SOCKET (an
        // external client — skhd/AeroSpace bound to pounce-palette, a script)
        // while the daemon's own in-process hotkey is registered yet has never
        // fired. That's the signature of an external tool shadowing ⌘Space: the
        // user pays a process-spawn + socket hop every summon instead of the warm
        // ~12ms path. Log it once so the footgun is visible without running
        // `pounce doctor`. (Deliberately not gated on the combo matching, since
        // the client doesn't report which key triggered it.)
        if inv.launcher, DaemonMode.hotkeyEnabled, DaemonMode.hotkeyRegistered,
           !DaemonMode.hotkeyReceived, !DaemonMode.shadowHintLogged {
            DaemonMode.shadowHintLogged = true
            NSLog("pounce daemon: opened via external client while the in-process hotkey (\(DaemonMode.hotkeyCombo)) has never fired — an external tool (skhd/AeroSpace/Raycast) is likely bound to the same key and shadowing pounce's built-in instant hotkey. Unbind it there to use the fast path, or run `pounce doctor`.")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        let settings = Settings.load()   // re-read per request so edits apply live
        let metrics = settings.metrics

        DispatchQueue.main.async {
            // Only one palette window exists, so a new request supersedes any
            // already on screen. Release the previous request's waiter first (fire
            // its resultSink with an empty result) so its now-detached handler
            // thread unblocks and closes its socket, instead of leaking — blocked
            // in semaphore.wait() with its clientFD open — behind the new window.
            ui.resultSink?("")
            ui.resultSink = nil
            Theme.current = settings.palette
            state.reset()
            state.metrics = metrics
            if inv.cheatsheet {
                state.loadCheatsheet(path: inv.cheatsheetPath, placeholder: inv.placeholder)
            } else {
                state.load(lines: itemLines, placeholder: inv.placeholder, icon: inv.icon,
                           launcher: inv.launcher, maxEmpty: inv.maxEmpty, chain: inv.chain)
            }
            ui.resultSink = { r in result = r; semaphore.signal() }
            ui.present()
        }

        semaphore.wait()

        if !result.isEmpty {
            let resultData = (result + "\n").data(using: .utf8)!
            resultData.withUnsafeBytes { ptr in _ = write(clientFD, ptr.baseAddress!, resultData.count) }
        }
        close(clientFD)
    }
}

// MARK: - Client Mode

enum ClientMode {
    static func parseArgs() -> Invocation {
        var inv = Invocation()
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "-p", "--placeholder": if !args.isEmpty { inv.placeholder = args.removeFirst() }
            case "-i", "--icon":        if !args.isEmpty { inv.icon = args.removeFirst() }
            case "--launcher":          inv.launcher = true
            case "--cheatsheet":
                inv.cheatsheet = true
                // The JSON path is optional (defaults in Invocation) — don't
                // swallow a following flag as the path.
                if let next = args.first, !next.hasPrefix("--") { inv.cheatsheetPath = args.removeFirst() }
            case "--max-empty":         if !args.isEmpty { inv.maxEmpty = Int(args.removeFirst()) }
            case "--chain":             inv.chain = true
            // An unrecognised flag used to be ignored, which is the worst possible
            // handling for the five mode flags this release removed: with no stdin
            // to show, `pounce --clipboard` would have opened an EMPTY generic
            // picker and looked broken rather than telling you what to type. So
            // flags fail loudly, and the ones that moved name where they went.
            case let flag where flag.hasPrefix("-"):
                let moved = [
                    "--clipboard": "mode:clipboard",
                    "--emoji": "mode:emoji",
                    "--screenshots": "mode:screenshots",
                    "--camera": "mode:camera",
                    "--find-files": "mode:filesearch",
                ]
                if let target = moved[flag] {
                    FileHandle.standardError.write(Data(
                        "pounce: \(flag) is gone — the built-in windows are items now: `pounce run \(target)`\n".utf8))
                } else {
                    FileHandle.standardError.write(Data(
                        "pounce: unknown option \(flag) (see `pounce --help`)\n".utf8))
                }
                exit(64)
            default: break
            }
        }
        return inv
    }

    // `override` bypasses argv parsing for callers that aren't a CLI parse —
    // today only AppLaunchMode (LoginItem.swift), which summons the launcher
    // from a Finder double-click where argv carries nothing.
    static func run(_ override: Invocation? = nil) {
        var stdinLines: [String] = []
        if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
            while let line = readLine() { stdinLines.append(line) }
        }
        let inv = override ?? parseArgs()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { runDirect(lines: stdinLines, inv: inv); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            SocketConfig.path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(strlen(cstr) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addrLen) }
        }) == 0
        if !connected { close(fd); runDirect(lines: stdinLines, inv: inv); return }

        // Two client-side modes left; the built-in windows arrive as RUN instead.
        let mode = inv.launcher ? "launcher" : (inv.cheatsheet ? "cheatsheet" : "")
        let maxEmpty = inv.maxEmpty.map(String.init) ?? ""
        var payload = "CONFIG\t\(inv.placeholder ?? "")\t\(inv.icon ?? "")\t\(mode)\t\(maxEmpty)\t\(inv.cheatsheetPath)\t\(inv.chain ? "1" : "")\n"
        for line in stdinLines { payload += line + "\n" }

        if let data = payload.data(using: .utf8) {
            data.withUnsafeBytes { ptr in _ = write(fd, ptr.baseAddress!, data.count) }
        }
        shutdown(fd, SHUT_WR)

        var resultData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            resultData.append(contentsOf: buf[0..<n])
        }
        close(fd)

        if let result = String(data: resultData, encoding: .utf8)?.trimmingCharacters(in: .newlines),
           !result.isEmpty {
            print(result); exit(0)
        } else {
            exit(1)
        }
    }

    // Fallback when the daemon is not running.
    static func runDirect(lines: [String], inv: Invocation) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let state = DaemonState()
        let ui = PounceUI(state: state)
        let settings = Settings.load()
        state.metrics = settings.metrics
        Theme.current = settings.palette
        if inv.cheatsheet {
            state.loadCheatsheet(path: inv.cheatsheetPath, placeholder: inv.placeholder)
        } else {
            state.load(lines: lines, placeholder: inv.placeholder, icon: inv.icon,
                       launcher: inv.launcher, maxEmpty: inv.maxEmpty, chain: inv.chain)
        }

        ui.resultSink = { result in
            if result.isEmpty { exit(1) }
            print(result); NSApp.terminate(nil)
        }
        DispatchQueue.main.async { ui.present() }
        app.run()
    }
}
