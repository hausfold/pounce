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
      pounce [-p <prompt>] [-i <sf-symbol>] [--max-empty <n>] [--chain [keys]]
             [--actions <spec>] [--draft <key>]
        generic picker: reads lines from stdin, prints the chosen one

        Return on text that matched no row prints "<action>\\t<text>", where
        action is enter / cmd / opt / ctrl — the same shape a row commit uses,
        so one step can offer several verbs. Shift+Return inserts a newline;
        Esc clears the box before a second Esc dismisses it.

        --chain [keys]   these commits feed another pounce step — hold the
                         window up with the loading skeleton instead of fading
                         out. Comma-separated (default "enter"); name only the
                         actions whose follow-up is another palette, so one
                         that needs the screen (⌘↵ → screencapture) still fades.
        --actions <spec> label the action bar for a step with no rows:
                         "Spawn|shift:New line|cmd:Screenshot|opt:Drafts"
        --draft <key>    keep the typed text on Esc / click-away, filed under
                         <key> (see `drafts` below). For a step that asks for a
                         paragraph, where a stray click would otherwise take it.
        --query <text>   open with the box already holding <text>, caret at the
                         end — a draft handed back for editing, not a filter.

    modes:
      --launcher             apps + commands palette (what the hotkey opens)
      --cheatsheet [path]    cheatsheet overlay (default ~/.config/pounce/cheatsheet.json)

    running one item:
      run <item-key>            run a single item by the key config.json's
                                `items` map uses — `cmd:emoji`,
                                `mode:clipboard`, `app:/Applications/Foo.app`,
                                `shortcut:<uuid>` (`shortcuts list
                                --show-identifiers`).
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

    drafts (what --draft kept):
      drafts <key> save         file stdin as a draft under <key> — for a step
                                that LEAVES the box deliberately (⌥↵ "show my
                                drafts"), which is a commit, not a dismissal
      drafts <key> list         one line per draft, newest first:
                                "<index>\\t<one-line preview>\\t<age>" — ready to
                                turn into picker rows
      drafts <key> get <index>  print that draft's full text (newlines intact)
      drafts <key> rm <index>   forget one
      drafts <key> clear        forget all of them

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

    settings:
      config                    print the config path
      config print              print an annotated config to stdout, touching
                                nothing — pipe it, or diff it against yours
      config init               write config.json with EVERY setting at its
                                default, documented and commented out — you
                                learn the settings by reading your own config.
                                Uncomment what you want, delete the rest.
                                --force replaces an existing one (otherwise it
                                writes config.json.new beside it).

    housekeeping:
      --daemon                  run the resident daemon (launchd uses this; also
                                hosts the MRU window switcher when config.json
                                sets windows.enabled — see docs/reference.md)
      autostart on|off|status   start the daemon at login via a self-registered
                                login item (System Settings → Login Items).
                                For drag-installs of Pounce.app; Homebrew users
                                use `brew services`, the haus desktop wires
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
    docs:   https://hausfold.co/docs/haus/reference/pounce/
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
        } else if args.count >= 2 && args[1] == "drafts" {
            // Positional, like `focus`/`doctor`/`config`. Pure file I/O — never
            // opens a window and never touches the daemon, so a command script
            // can list/prune drafts without a palette flashing up.
            DraftsMode.run(args: Array(args.dropFirst(2)))
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
        } else if args.count >= 2 && args[1] == "config" {
            // Positional like `focus`/`doctor` (see those branches for why).
            // `pounce config init` writes an annotated config.json: every
            // setting at its default, documented, and commented out.
            ConfigMode.run(op: args.count >= 3 ? args[2] : nil, args: args)
        } else if args.contains("--migrate-autostart") {
            Autostart.migrateLegacyRegistration()
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
// haus user's AeroSpace binding mode, skhd, a Shortcut, a Stream Deck. They
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

// `pounce drafts <key> …`: read back what `--draft <key>` kept.
//
// Deliberately four dumb verbs over a file rather than a built-in drafts WINDOW.
// The caller is a shell script that already knows how to build picker rows, and
// keeping it that way means the drafts list gets the caller's own actions and
// wording for free — a "Spawn Agent" drafts list can say Use / Delete / Clear
// all, which a generic mode baked into the daemon could not.
//
// The split between `list` and `get` is the point: `list` is guaranteed
// one-line-per-draft (previews are whitespace-folded) so `while read` in bash is
// safe, and `get` hands back the real text with its newlines intact. A single
// command doing both would have forced the shell to un-escape.
enum DraftsMode {
    static func run(args: [String]) {
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("pounce drafts: \(message)\n".utf8))
            exit(2)
        }
        guard let key = args.first, !key.isEmpty else {
            fail("needs a key — `pounce drafts <key> save|list|get <i>|rm <i>|clear`")
        }
        let op = args.count > 1 ? args[1] : "list"
        switch op {
        case "list":
            let now = Int(Date().timeIntervalSince1970)
            for (i, d) in Drafts.load(key: key).enumerated() {
                print("\(i)\t\(Drafts.preview(d.text))\t\(Drafts.ago(d.stamp, now: now))")
            }
        case "get":
            guard args.count > 2, let i = Int(args[2]) else { fail("`get` needs an index") }
            let drafts = Drafts.load(key: key)
            guard i >= 0 && i < drafts.count else { exit(1) }
            // No trailing newline of our own: the draft IS the output, and
            // `$(...)` strips one anyway — printing it raw keeps a prompt that
            // deliberately ends in a blank line from silently losing it.
            FileHandle.standardOutput.write(Data(drafts[i].text.utf8))
        case "save":
            // Text on stdin. The daemon files a draft on DISMISSAL, but a caller
            // that deliberately leaves the box (⌥↵ "show me my drafts") has
            // committed, not dismissed — without this the in-progress text would
            // be the one thing the drafts list can't offer you back.
            let text = String(data: FileHandle.standardInput.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            exit(Drafts.save(key: key, text: text) ? 0 : 1)
        case "rm":
            guard args.count > 2, let i = Int(args[2]) else { fail("`rm` needs an index") }
            exit(Drafts.remove(key: key, index: i) ? 0 : 1)
        case "clear":
            Drafts.clear(key: key)
        default:
            fail("unknown op \(op) — expected save, list, get, rm or clear")
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
    // Which free-text commits the caller answers with ANOTHER `pounce`
    // invocation — so the window holds the loading skeleton rather than fading
    // out and re-opening. Only free-text commits are affected: picking a row
    // still lingers, because a row's follow-up may be a terminal action.
    var chainActions: Set<String> = []
    // Action-bar labels for a step that shows no rows ("Spawn|opt:Drafts").
    var actionSpec: String?
    // Where to file the typed text if this step is dismissed rather than
    // committed (Drafts.swift). nil → keep nothing.
    var draftKey: String?
    // Text the box opens with, caret at the end — a draft handed back for
    // editing. Not a filter: it is the user's own text returning.
    var query: String?
}

// MARK: - Daemon Mode

enum DaemonMode {
    // Retained for the daemon's lifetime so its Carbon handler stays installed.
    static var hotKey: HotKeyManager?
    // Retained so the ⌘Tab event tap stays alive.
    static var windowSwitcher: WindowSwitcher?
    // Retained so the app-scoped chords + page-walk tap stays alive (AppScoped.swift).
    static var appScoped: AppScopedKeys?
    static var mouseChords: MouseChords?
    // Teardown on SIGTERM/SIGINT (see run()). Off the main queue on purpose, so
    // the exit path doesn't depend on the UI thread being responsive.
    static let exitQueue = DispatchQueue(label: "co.hausfold.pounce.exit")
    static var exitSignalSources: [DispatchSourceSignal] = []
    // The AX window snapshot, shared by every feature that reads it (the ⌘Tab
    // switcher, auto-quit). One instance on purpose: the tracker keeps an
    // AXObserver on every running app, and a second copy would double that for no
    // new information. Created on first use, dropped when Accessibility goes away.
    static var windowTracker: WindowTracker?
    // Retained so the census hook the tracker calls has something to call.
    static var autoQuit: AutoQuit?
    // Fn/Globe is a modifier-only key, so its opt-in item binding uses a session
    // event tap rather than the Carbon manager above (FunctionKey.swift).
    static var functionKey: FunctionKeyHotKey?
    static var functionKeyRequest: (label: String, onFire: () -> Void)?
    static var functionKeyReportIndex: Int?
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
        guard let tracker = sharedWindowTracker() else {
            NSLog("pounce daemon: windows.enabled is set but Accessibility is not granted; window switcher off, stock \(combo) untouched (grant via `pounce --request-accessibility`)")
            return
        }
        if let switcher = WindowSwitcher(settings: settings, tracker: tracker) {
            windowSwitcher = switcher
            NSLog("pounce daemon: window switcher armed on \(combo)")
        } else {
            NSLog("pounce daemon: window switcher event tap failed to install; stock \(combo) untouched")
            releaseWindowTrackerIfUnused()
        }
    }

    // The one WindowTracker, built on first demand. nil without Accessibility:
    // the AX walk it exists to do returns nothing at all without the grant, so
    // there is no point paying for the observers.
    static func sharedWindowTracker() -> WindowTracker? {
        guard AXIsProcessTrusted() else { return nil }
        if windowTracker == nil { windowTracker = WindowTracker() }
        return windowTracker
    }

    // A tracker nobody reads is pure cost — an AXObserver per running app, an AX
    // walk per window event, an `aerospace` fork per population change. Callers
    // take it before they know whether they'll succeed (the switcher needs it to
    // construct), so whoever fails hands it back.
    static func releaseWindowTrackerIfUnused() {
        guard windowSwitcher == nil, autoQuit == nil, appScoped == nil else { return }
        windowTracker = nil
    }

    // Arms the app-scoped chords + workspace-page walk (AppScoped.swift). Same
    // Accessibility gate and live re-arming as the switcher: without the grant
    // the chords keep their stock meanings everywhere, which is exactly the
    // pass-through these features promise for every OTHER app anyway.
    static func armAppScoped(hotkeys: AppHotkeysSettings, pages: PageSwitcherSettings) {
        guard hotkeys.enabled || pages.enabled, appScoped == nil else { return }
        guard let run = runTargetHook else { return }
        guard AXIsProcessTrusted() else {
            NSLog("pounce daemon: appHotkeys/pages are set but Accessibility is not granted; scoped chords off (grant via `pounce --request-accessibility`)")
            return
        }
        // The tracker is only for the walk's "which pages are non-empty" read;
        // hotkeys alone shouldn't pay for AX observers on every app.
        let tracker = pages.enabled ? sharedWindowTracker() : nil
        if let keys = AppScopedKeys(settings: hotkeys, pages: pages,
                                    tracker: tracker, runTarget: run) {
            appScoped = keys
            let what = [hotkeys.enabled ? "\(hotkeys.scopes.count) scope(s)" : nil,
                        pages.enabled ? "page walk on \(pages.modifiers.joined(separator: "+"))+\(pages.key)" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            NSLog("pounce daemon: app-scoped keys armed (\(what))")
        } else {
            NSLog("pounce daemon: app-scoped keys event tap failed to install; chords keep their stock meanings")
            releaseWindowTrackerIfUnused()
        }
    }

    // Arms the mouse chords (MouseChords.swift). Same grant and live re-arming
    // story as the chords above — and the same graceful failure: without the
    // grant the click keeps whatever it meant to the app under the pointer,
    // which is the pass-through this feature already promises for every chord
    // it isn't bound to.
    static func armMouseChords(_ settings: MouseChordsSettings) {
        guard settings.enabled, mouseChords == nil else { return }
        guard AXIsProcessTrusted() else {
            NSLog("pounce daemon: mouseChords is set but Accessibility is not granted; mouse chords off (grant via `pounce --request-accessibility`)")
            return
        }
        if let chords = MouseChords(settings: settings) {
            mouseChords = chords
            let what = settings.chords
                .map { "\($0.modifiers.joined(separator: "+"))+\($0.button.rawValue)-click → \($0.action.rawValue)" }
                .joined(separator: ", ")
            NSLog("pounce daemon: mouse chords armed (\(what))")
        } else {
            NSLog("pounce daemon: mouse chords event tap failed to install; clicks keep their stock meanings")
        }
    }

    // Arms auto-quit (AutoQuit.swift). Idempotent and Accessibility-gated exactly
    // like the switcher above, and for the same reason: the grant may be ticked
    // after the daemon booted, and watchAccessibility calls this again when it is.
    static func armAutoQuit(_ settings: AutoQuitSettings) {
        guard settings.enabled, autoQuit == nil else { return }
        guard let tracker = sharedWindowTracker() else {
            NSLog("pounce daemon: autoQuit.enabled is set but Accessibility is not granted; auto-quit off (grant via `pounce --request-accessibility`)")
            return
        }
        let quitter = AutoQuit(settings: settings)
        // Weak: DaemonMode owns the quitter, and the tracker outlives it whenever
        // the switcher is also on.
        tracker.onCensus = { [weak quitter] census in quitter?.consume(census) }
        autoQuit = quitter
        let excluded = settings.exclude.isEmpty
            ? "nothing excluded" : "never quits \(settings.exclude.joined(separator: ", "))"
        NSLog("pounce daemon: auto-quit armed (\(settings.delay)s delay, \(excluded))")
    }

    // Arm a configured bare Fn/Globe item binding. Like the window switcher,
    // this is idempotent and is called both at startup and when Accessibility
    // flips on later, so granting Pounce never requires a daemon restart.
    static func armFunctionKeyBinding() {
        guard functionKey == nil, let request = functionKeyRequest else { return }
        guard AXIsProcessTrusted() else {
            NSLog("pounce daemon: binding \(request.label) needs Accessibility; Fn/Globe left to macOS (grant via `pounce --request-accessibility`)")
            updateFunctionKeyReport("\(request.label) — NEEDS Accessibility")
            return
        }
        if let binding = FunctionKeyHotKey(onFire: request.onFire) {
            functionKey = binding
            NSLog("pounce daemon: binding \(request.label) registered (Accessibility event tap)")
            updateFunctionKeyReport(request.label)
        } else {
            NSLog("pounce daemon: binding \(request.label) event tap failed to install; Fn/Globe left to macOS")
            updateFunctionKeyReport("\(request.label) — FAILED, event tap unavailable")
        }
    }

    static func updateFunctionKeyReport(_ line: String) {
        if let index = functionKeyReportIndex, bindingReport.indices.contains(index) {
            bindingReport[index] = line
        } else {
            functionKeyReportIndex = bindingReport.count
            bindingReport.append(line)
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
    static func watchAccessibility(windows: WindowSwitcherSettings, autoQuit quit: AutoQuitSettings,
                                   appHotkeys: AppHotkeysSettings, pages: PageSwitcherSettings,
                                   mouseChords chords: MouseChordsSettings) {
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let now = AXIsProcessTrusted()
            if now != lastTrusted {
                lastTrusted = now
                NSLog("pounce daemon accessibility trusted=\(now) (changed while running)")
                if now {
                    armWindowSwitcher(windows)
                    armAutoQuit(quit)
                    armFunctionKeyBinding()
                    armAppScoped(hotkeys: appHotkeys, pages: pages)
                    armMouseChords(chords)
                } else if windowSwitcher != nil {
                    windowSwitcher = nil   // deinit disables the tap + removes the run-loop source
                    NSLog("pounce daemon: Accessibility revoked; window switcher disarmed, stock switcher restored")
                }
                if !now {
                    // Both go, and the tracker with them: without the grant its AX
                    // walk reports every app as windowless, which is precisely the
                    // input that would make auto-quit close everything you have
                    // open. Dropping it also means a re-grant rebuilds the
                    // observers from a clean slate.
                    if autoQuit != nil {
                        autoQuit = nil
                        NSLog("pounce daemon: Accessibility revoked; auto-quit disarmed")
                    }
                    if appScoped != nil {
                        appScoped = nil   // deinit disables the tap; chords fall back to stock
                        NSLog("pounce daemon: Accessibility revoked; app-scoped keys disarmed")
                    }
                    if mouseChords != nil {
                        mouseChords = nil   // ditto — the click reaches the app again
                        NSLog("pounce daemon: Accessibility revoked; mouse chords disarmed")
                    }
                    releaseWindowTrackerIfUnused()
                }
                if !now, functionKey != nil {
                    functionKey = nil
                    if let request = functionKeyRequest {
                        updateFunctionKeyReport("\(request.label) — NEEDS Accessibility")
                    }
                    NSLog("pounce daemon: Accessibility revoked; Fn/Globe binding disarmed, stock action restored")
                }
            }
        }
    }

    static func run() {
        Autostart.scheduleLegacyMigrationIfNeeded()

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

        // warm() is unconditional — config is re-read on every ⌘Space, so turning
        // `shortcuts.enabled` back on has to work without a daemon restart, and a
        // warm snapshot is what makes that first summon show the library instead
        // of waiting on a cold CLI run. What the setting gates is the *work*: a
        // store told it's off skips every refresh (see ShortcutsStore.rebuild).
        ShortcutsStore.shared.setEnabled(settings.shortcuts.enabled)
        ShortcutsStore.shared.warm()

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
            settings.apply()
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
            settings.apply()
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
            case .shortcut(let id):
                ShortcutsStore.run(id: id)
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
                settings.apply()
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

            let fire: () -> Void = node.isLeaf
                ? { runTarget(node.target!) }
                : { leaderRunner.arm(node) }

            // A bare Fn/Globe tap is a modifier-only gesture: Carbon cannot
            // register it, so hand the one leaf to FunctionKeyHotKey. Modifiers
            // or leader children would be ambiguous with ordinary Fn chords and
            // are rejected explicitly instead of arming something surprising.
            if FunctionKeyHotKey.matches(step.key) {
                guard node.isLeaf, step.modifiers.isEmpty else {
                    NSLog("pounce daemon: binding \(label) uses Fn/Globe with modifiers or as a leader; only a bare one-step `fn` binding is supported")
                    bindingReport.append("\(label) — only bare one-step `fn` is supported")
                    continue
                }
                if let existing = functionKeyRequest {
                    NSLog("pounce daemon: binding conflict — \(label) and \(existing.label) name the same physical Fn/Globe key")
                    bindingReport.append("\(label) — conflicts with \(existing.label)")
                    continue
                }
                // `"fnKey": "remap"` takes Fn away from macOS at the HID layer,
                // which turns it into an ordinary F19 — so it registers through
                // the Carbon path below like any other key, with no tap and no
                // Accessibility grant. Fall through to the tap only if the remap
                // didn't take (an external keyboard that doesn't expose Fn to
                // IOHID), so the binding still works as well as it used to.
                if settings.fnKey == .remap, FunctionKeyRemap.apply() {
                    let target = FunctionKeyRemap.targetKeyName
                    if let keyCode = HotKeyParser.keyCode(for: target),
                       manager.register(keyCode: keyCode, modifiers: 0, onFire: fire) {
                        NSLog("pounce daemon: binding \(label) registered (Fn remapped to \(target) at the HID layer)")
                        bindingReport.append("\(label) — via HID remap to \(target)")
                        continue
                    }
                    // Another app already holds F19. Hand Fn back before falling
                    // through to the tap: keeping the remap here would be the
                    // worst of both worlds — Fn+arrows gone AND nothing bound.
                    FunctionKeyRemap.restore()
                    NSLog("pounce daemon: \(target) is already taken, so the Fn remap was undone; falling back to the event tap for \(label)")
                    // No report line here: the tap path below owns this binding's
                    // line from now on, and two would look like two bindings.
                }
                functionKeyRequest = (label, fire)
                updateFunctionKeyReport("\(label) — waiting for Accessibility")
                continue
            }

            guard let keyCode = HotKeyParser.keyCode(for: step.key) else {
                NSLog("pounce daemon: binding \(label) uses unknown key '\(step.key)'; skipped")
                bindingReport.append("\(label) — unknown key '\(step.key)'")
                continue
            }
            let modifiers = HotKeyParser.modifierMask(for: step.modifiers)

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

        armFunctionKeyBinding()

        // The MRU window switcher (default ⌘Tab, see Switcher.swift). Unlike the
        // palette hotkey (Carbon, no permissions), taking ⌘Tab needs an event
        // tap, which macOS gates behind Accessibility — without the grant the
        // stock switcher is left untouched, so enabling this can never brick
        // window switching. If the grant is only ticked later, watchAccessibility
        // arms it live, so this boot-time call may find no grant and no-op.
        armWindowSwitcher(settings.windows)

        // Quit-on-last-window-close (AutoQuit.swift). Same grant, same live-arming
        // story as the switcher above — and it shares that feature's AX snapshot,
        // so with both on there is still only one tracker.
        armAutoQuit(settings.autoQuit)

        // App-scoped chords + the workspace-page walk (AppScoped.swift). Same
        // grant and live-arming story again; runTargetHook is already set above,
        // which is what lets a scoped chord fire the same dispatch a Carbon
        // binding does.
        armAppScoped(hotkeys: settings.appHotkeys, pages: settings.pages)

        // Modifier+click on the window under the pointer (MouseChords.swift).
        // Its own tap, not the one above: the event masks are disjoint and so
        // are the switches, so a machine that wants one shouldn't install the
        // other.
        armMouseChords(settings.mouseChords)

        // Clipboard history watcher: poll the pasteboard while the daemon lives.
        if settings.clipboard.enabled {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                ClipboardStore.shared.poll()
            }
        }

        // Give Fn back on the way out. A no-op unless `"fnKey": "remap"` actually
        // installed a mapping; a hard kill skips it, which is why the mapping is
        // deliberately the non-persistent kind (a reboot undoes it regardless).
        //
        // Handled through a DispatchSource rather than a C signal handler because
        // the restore has to run hidutil and read its output: malloc, Foundation,
        // and a blocking wait are all illegal in a real handler, and the one time
        // they'd deadlock is the one time we need them. The source runs on its own
        // queue so a wedged main thread can't hold up the exit either.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: exitQueue)
            source.setEventHandler {
                FunctionKeyRemap.restore()
                unlink(SocketConfig.path)
                _exit(0)
            }
            source.resume()
            exitSignalSources.append(source)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            startSocketServer(state: state, ui: ui)
        }

        NSLog("pounce daemon started, listening on \(SocketConfig.path)")
        // Snapshot at boot; watchAccessibility() then logs any later transition
        // so the grant's true running state is always in the log, not just the
        // value that happened to hold the instant the daemon launched.
        lastTrusted = AXIsProcessTrusted()
        NSLog("pounce daemon accessibility trusted=\(lastTrusted!) (startup snapshot)")
        watchAccessibility(windows: settings.windows, autoQuit: settings.autoQuit,
                           appHotkeys: settings.appHotkeys, pages: settings.pages,
                           mouseChords: settings.mouseChords)
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
            // Field 7 used to be the flag "1" for --chain; it carries the action
            // list now. Still read the old spelling: a client and a daemon from
            // different builds meet over this socket every time the app updates
            // while a daemon is resident, and "chain silently stopped working"
            // would show up as a fade-out mid two-step command.
            if p.count > 6 && !p[6].isEmpty {
                inv.chainActions = p[6] == "1" ? ["enter"]
                    : Set(p[6].split(separator: ",").map(String.init))
            }
            if p.count > 7 && !p[7].isEmpty { inv.actionSpec = p[7] }
            if p.count > 8 && !p[8].isEmpty { inv.draftKey = p[8] }
            // Field 10 is the seed query, which is USER TEXT and so the one
            // field that can legitimately contain newlines and tabs — the very
            // characters this line-and-tab protocol is built out of. The client
            // escapes it (Drafts.encode) and it is decoded back here.
            if p.count > 9 && !p[9].isEmpty { inv.query = Drafts.decode(p[9]) }
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
            settings.apply()
            state.reset()
            state.metrics = metrics
            if inv.cheatsheet {
                state.loadCheatsheet(path: inv.cheatsheetPath, placeholder: inv.placeholder)
            } else {
                state.load(lines: itemLines, placeholder: inv.placeholder, icon: inv.icon,
                           launcher: inv.launcher, maxEmpty: inv.maxEmpty,
                           chainActions: inv.chainActions,
                           freeTextActions: inv.actionSpec.map(ItemAction.parseSpec) ?? [],
                           draftKey: inv.draftKey, seedQuery: inv.query ?? "")
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
            case "--actions":           if !args.isEmpty { inv.actionSpec = args.removeFirst() }
            case "--draft":             if !args.isEmpty { inv.draftKey = args.removeFirst() }
            case "--query":             if !args.isEmpty { inv.query = args.removeFirst() }
            case "--chain":
                // The action list is optional and bare `--chain` still means
                // "chain the plain Return", which is what every existing caller
                // wrote. Same guard as --cheatsheet: don't swallow a following
                // flag as the value.
                if let next = args.first, !next.hasPrefix("-") {
                    inv.chainActions = Set(args.removeFirst().split(separator: ",").map(String.init))
                } else {
                    inv.chainActions = ["enter"]
                }
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
        // Positional TSV; new fields only ever get APPENDED, so an older daemon
        // meeting a newer client just ignores the tail rather than mis-reading a
        // field (see the reader in handleClient).
        let chain = inv.chainActions.sorted().joined(separator: ",")
        var payload = "CONFIG\t\(inv.placeholder ?? "")\t\(inv.icon ?? "")\t\(mode)\t\(maxEmpty)\t\(inv.cheatsheetPath)\t\(chain)\t\(inv.actionSpec ?? "")\t\(inv.draftKey ?? "")\t\(Drafts.encode(inv.query ?? ""))\n"
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
        settings.apply()
        if inv.cheatsheet {
            state.loadCheatsheet(path: inv.cheatsheetPath, placeholder: inv.placeholder)
        } else {
            state.load(lines: lines, placeholder: inv.placeholder, icon: inv.icon,
                       launcher: inv.launcher, maxEmpty: inv.maxEmpty,
                       chainActions: inv.chainActions,
                       freeTextActions: inv.actionSpec.map(ItemAction.parseSpec) ?? [],
                       draftKey: inv.draftKey, seedQuery: inv.query ?? "")
        }

        ui.resultSink = { result in
            if result.isEmpty { exit(1) }
            print(result); NSApp.terminate(nil)
        }
        DispatchQueue.main.async { ui.present() }
        app.run()
    }
}
