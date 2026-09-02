import Foundation
import ApplicationServices

// MARK: - pounce doctor
//
// A one-shot health check for the palette hotkey path. It exists because a
// whole class of "pounce is slow / won't open" reports trace to the SAME root
// cause: an external hotkey tool (skhd, AeroSpace, Raycast) is bound to the same
// key pounce registers, so the keypress never reaches the daemon's fast
// in-process path and instead spawns a client on every summon. That failure is
// invisible — registration reports success, the palette still opens (slowly) —
// so it historically cost many rounds of back-and-forth to find. doctor surfaces
// it, and the neighbouring snags (daemon down, missing Accessibility, a macOS
// system-shortcut clash), in one command.
//
// It combines two views: what the live daemon knows about itself (queried over
// the socket — only it knows whether the in-process hotkey has actually FIRED)
// and what the environment looks like from outside (system shortcuts, running
// hotkey daemons, their configs).

enum DoctorMode {
    private struct Status {
        let version: String
        let accessibility: Bool
        let hotkeyEnabled: Bool
        let hotkeyCombo: String
        let hotkeyRegistered: Bool
        let hotkeyReceived: Bool
        let bindings: [String]
    }

    /// One line of the report, kept as data rather than only as text so
    /// `--json` doesn't have to re-derive the verdict by parsing back the ✔/⚠/✘
    /// it just printed. The human report is rendered FROM these, so a check that
    /// exists in one view exists in the other by construction.
    struct Check {
        enum Level: String { case ok, warn, bad, note }
        let level: Level
        let message: String
    }

    /// Everything one run of the check knows. `text` and `healthy` are what the
    /// two older callers already used; the rest is what `--json` publishes.
    struct Report {
        let text: String
        let healthy: Bool
        let checks: [Check]
        let problems: [String]
        let combo: String
        let daemon: [String: Any]
        let hotkey: [String: Any]
    }

    /// `pounce doctor [--json]` — print the report, exit 0 when healthy.
    static func run(args: [String] = []) -> Never {
        // A mistyped `--jsonx` must not fall through to the human report at
        // exit 0: that feeds prose to a parser and calls it success, which is
        // the exact failure `--json` exists to remove.
        for arg in args where arg != "--json" {
            FileHandle.standardError.write(Data(
                "pounce doctor: unknown flag '\(arg)' — doctor takes --json and nothing else\n".utf8))
            exit(2)
        }
        let report = report()
        if args.contains("--json") {
            Json.emit([
                "healthy": report.healthy,
                "version": pounceVersion,
                "daemon": report.daemon,
                "hotkey": report.hotkey,
                "checks": report.checks.map { ["level": $0.level.rawValue, "message": $0.message] },
                "problems": report.problems,
            ])
        } else {
            print(report.text)
        }
        exit(report.healthy ? 0 : 1)
    }

    /// The same report, as a string.
    ///
    /// Split out for `pounce report`, which puts it straight into the bug
    /// form's diagnostics field. The form asks the reporter to run `pounce
    /// doctor` and paste the output; this is that, without the two steps where
    /// a report gets lost — and without the paste that arrives truncated
    /// because a terminal scrolled.
    static func report() -> Report {
        let settings = Settings.load()
        let status = queryDaemon()
        let combo = status?.hotkeyCombo
            ?? "\(settings.hotkey.modifiers.joined(separator: "+"))+\(settings.hotkey.key)"

        var out: [String] = []
        var lines: [String] = []
        var problems: [String] = []
        var checks: [Check] = []
        func ok(_ s: String)   { lines.append("  \u{2714} \(s)"); checks.append(.init(level: .ok, message: s)) }
        func warn(_ s: String) { lines.append("  \u{26A0} \(s)"); checks.append(.init(level: .warn, message: s)) }
        func bad(_ s: String)  { lines.append("  \u{2718} \(s)"); checks.append(.init(level: .bad, message: s)) }
        /// An aside under the check above it — no glyph, no verdict of its own.
        func note(_ s: String) { lines.append("    (\(s))"); checks.append(.init(level: .note, message: s)) }

        out.append("pounce doctor\n")

        // Daemon + version.
        if let status {
            ok("daemon running — version \(status.version)")
        } else {
            bad("daemon not running — start it: `brew services start pounce`")
            problems.append("The daemon isn't running, so nothing responds to the hotkey.")
        }

        // Accessibility (only knowable from the daemon's own identity).
        if let status {
            if status.accessibility {
                ok("Accessibility granted")
            } else {
                warn("Accessibility not granted — auto-paste, Fn/Globe item bindings, the \u{2318}Tab switcher, "
                     + "auto-quit, and --transform need it (`pounce --request-accessibility`)")
            }
        }

        // The crux: registered vs. actually received.
        if let status, !status.hotkeyEnabled {
            warn("in-process hotkey disabled in config (hotkey.enabled=false) — you're "
                 + "relying on an external tool to bind \(combo)")
        } else if let status {
            if status.hotkeyRegistered {
                ok("hotkey \(combo) registered")
            } else {
                bad("hotkey \(combo) failed to register — another app already owns it")
                problems.append("Another app holds \(combo); pounce couldn't register it.")
            }
            if status.hotkeyReceived {
                ok("hotkey has fired — you're on the fast in-process path")
            } else if status.hotkeyRegistered {
                bad("hotkey \(combo) has NEVER fired since the daemon started")
                problems.append("\(combo) is registered but has never reached pounce — "
                                + "something is intercepting it (see below).")
            }
        }

        // Per-item bindings from config.json's `items` map. The daemon reports
        // what it actually armed at startup, which is the only way to see that a
        // binding lost its combo to another app — from the user's side a dead
        // binding and a mistyped target look identical (nothing happens).
        if let status, !status.bindings.isEmpty {
            for line in status.bindings {
                if line.hasPrefix("conflict — ") {
                    bad(line)
                    problems.append("Two bindings collide, so one can never fire: "
                                    + line.replacingOccurrences(of: "conflict — ", with: ""))
                } else if line.contains("FAILED") || line.contains("unknown key")
                    || line.contains("no such command") {
                    bad("binding \(line)")
                    problems.append("A binding in config.json's `items` map isn't armed: \(line)")
                } else if line.contains("also bound to") {
                    warn("binding \(line)")
                } else {
                    ok("binding \(line)")
                }
            }
        }

        // Rows scoped to a workspace or an app (`items`' `workspaces` /
        // `bundleIds`). These fail QUIETLY by construction: a row that is never
        // listed looks exactly like a row you never installed, there is no error
        // anywhere, and the palette is the wrong place to explain itself. The
        // report is the only place that can say it, so it says it — both what
        // each scoped row asks for, and whether it would be listed from here.
        let scopedItems = settings.items.entries.filter { $0.value.isScoped }.sorted { $0.key < $1.key }
        if !scopedItems.isEmpty {
            let here = WorkspaceMRU.current(file: settings.pages.mruFile)
            let wantsWorkspace = scopedItems.contains { !$0.value.workspaces.isEmpty }

            // The silent no-op: rows asking about a workspace on a machine that
            // never says which one it is on. They are listed everywhere, which
            // reads as "the setting did nothing" and is impossible to tell from
            // a typo in the workspace name.
            if wantsWorkspace, here == nil {
                if let file = settings.pages.mruFile, !file.isEmpty {
                    bad("\"pages\".mruFile (\(file)) can't be read, so pounce doesn't know which "
                        + "workspace is in front — every `workspaces` row below is listed everywhere")
                    problems.append("`pages.mruFile` points at a file pounce can't read (\(file)); "
                                    + "the `workspaces` scoping in `items` is doing nothing.")
                } else {
                    bad("rows are scoped to workspaces, but no \"pages\".mruFile is set — pounce has "
                        + "no way to know which workspace is in front, so they are listed everywhere")
                    problems.append("Set `pages.mruFile` to the recency file your window manager's "
                                    + "workspace-change hook writes; without it `workspaces` scoping "
                                    + "in `items` does nothing.")
                }
            } else if let here {
                ok("workspace in front, per \"pages\".mruFile: \(here)")
            }

            for (key, item) in scopedItems {
                var scope: [String] = []
                if !item.workspaces.isEmpty {
                    scope.append("workspaces " + item.workspaces.joined(separator: ", "))
                }
                if !item.bundleIds.isEmpty {
                    scope.append("apps " + item.bundleIds.joined(separator: ", "))
                }
                let asked = scope.joined(separator: " + ")
                // Only the workspace half can be judged from here: `bundleIds` is
                // about whatever was frontmost when you press the key, and the
                // app in front right now is the terminal running this command.
                if let here, !item.workspaces.isEmpty,
                   !item.workspaces.contains(where: { ItemSetting.workspaceMatches($0, here) }) {
                    warn("\(key) is listed only on \(asked) — not from \(here), where you are now")
                } else {
                    ok("\(key) is listed only on \(asked)")
                }
            }
        }

        // The same silence, one layer over: a command script that scopes its own
        // row with a `whenFile` header. `items` scoping lives in config.json and
        // is reported above; this lives in the script, so nothing the user can
        // read explains an absent row — least of all the palette, which simply
        // does not draw it. Report what each one asks for and what its file says
        // right now, so "I never installed it" and "it is answering no" stop
        // looking identical.
        let registry = CommandRegistry()
        registry.refresh()
        // …when this process can see the commands at all. The command dirs come
        // from POUNCE_BUILTIN_DIR / POUNCE_EXTRA_COMMAND_DIRS, which a packager
        // exports to the DAEMON (and to pounce-palette) and not to your shell —
        // so on a Nix install `pounce doctor` from a terminal scans
        // ~/.config/pounce/commands alone and would report "no scoped rows" for a
        // palette full of them. Say so instead, and only where it is true: a
        // Homebrew keg resolves its built-ins from the binary's own path.
        let env = ProcessInfo.processInfo.environment
        let dirsInEnv = ["POUNCE_BUILTIN_DIR", "POUNCE_EXTRA_COMMAND_DIRS"]
            .contains { !(env[$0] ?? "").isEmpty }
        if !dirsInEnv, CommandRegistry.defaultBuiltinDirExists == false {
            warn("command scopes not checked — this shell has no POUNCE_BUILTIN_DIR / "
                 + "POUNCE_EXTRA_COMMAND_DIRS, so only ~/.config/pounce/commands was read. "
                 + "Run doctor with the same environment the palette gets to include a "
                 + "packager's commands.")
        }
        for scope in registry.scopes {
            let path = CommandRegistry.expandTilde(
                scope.whenFile, home: FileManager.default.homeDirectoryForCurrentUser.path)
            let exists = FileManager.default.fileExists(atPath: path)
            if scope.listed {
                ok("cmd:\(scope.id) is listed while \(scope.whenFile) does not say 0"
                   + (exists ? "" : " — that file does not exist yet, which is a yes"))
            } else {
                warn("cmd:\(scope.id) is NOT listed right now: \(scope.whenFile) says 0")
            }
        }

        // Whenever anything binds `fn`, report which of the two mechanisms is
        // actually carrying it — they fail in completely different ways and the
        // symptom (macOS's own picker appears) looks identical from outside.
        if settings.items.bindings.contains(where: {
            $0.sequence.steps.count == 1 && FunctionKeyHotKey.matches($0.sequence.steps[0].key)
        }) {
            if settings.fnKey == .remap {
                // The reliable one. It can still fail silently: a keyboard that
                // doesn't expose Fn to IOHID, or another tool rewriting
                // UserKeyMapping out from under us, leaves Fn back with macOS.
                if FunctionKeyRemap.isActive {
                    ok("Fn remapped to \(FunctionKeyRemap.targetKeyName.uppercased()) at the HID layer "
                       + "— macOS never sees a Fn key")
                } else if status != nil {
                    // Only a problem when a daemon is actually up to have installed
                    // it; with the daemon down this is the same single fault as the
                    // "not running" line above, and saying it twice reads as two.
                    bad("\"fnKey\": \"remap\" is configured but no Fn mapping is live — "
                        + "macOS still owns the key")
                    problems.append("The HID remap isn't installed (another tool rewrote "
                                    + "UserKeyMapping, the keyboard re-enumerated after a "
                                    + "replug or sleep, or it doesn't expose Fn to IOHID). "
                                    + "Check `hidutil property --get UserKeyMapping`; "
                                    + "restarting the daemon reinstalls it.")
                }
            } else {
                // The tap route shares the key with HIToolbox's own Globe handler,
                // which lives in every process and reads Fn below the event stream
                // — so pounce cannot suppress it, and turning the system action off
                // is the user's only lever. Even that is unreliable: the value is
                // read from login-session state, so it needs a logout to take.
                let action = globeKeyAction()
                if action == 0 {
                    // Deliberately hedged: this reads the stored pref, while the
                    // handler reads login-session state. Set-but-not-logged-out
                    // looks exactly like this line and still races.
                    ok("macOS's own \u{1F310} key action is set to Do Nothing "
                       + "(needs one logout to take effect if you just changed it)")
                } else {
                    warn("macOS's own \u{1F310} key action is \(globeActionName(action)) — it fires "
                         + "alongside your Fn binding, and the tap can't suppress it")
                    problems.append("Turn off macOS's own Globe action: System Settings \u{2192} Keyboard "
                                    + "\u{2192} \u{201C}Press \u{1F310} key to\u{201D} \u{2192} Do Nothing "
                                    + "(then log out — it's read from session state). For a binding that "
                                    + "can't be raced at all, set \"fnKey\": \"remap\".")
                }
            }
        }

        // A macOS system shortcut on the same combo (Spotlight, input sources, …).
        if let conflict = HotKeyConflict.systemConflict(keyName: settings.hotkey.key,
                                                        modifierNames: settings.hotkey.modifiers) {
            bad("\(combo) is also bound to \(conflict) — macOS routes the key there")
            problems.append("Disable that shortcut: System Settings \u{2192} Keyboard \u{2192} "
                            + "Keyboard Shortcuts.")
        } else {
            ok("no macOS system shortcut on \(combo)")
        }

        // External hotkey daemons that could be intercepting the key with an event tap.
        let daemons = runningHotkeyDaemons()
        if daemons.isEmpty {
            ok("no external hotkey daemons running")
        } else {
            for d in daemons { warn("external hotkey daemon running: \(d)") }
        }

        // Their configs, scanned for a binding that runs the pounce LAUNCHER
        // (pounce-palette / `pounce --launcher`) — the thing that duplicates the
        // in-process hotkey. Item bindings (pounce run mode:emoji on another
        // key) are legitimate and deliberately not flagged. A launcher binding
        // is only a *problem* when the in-process hotkey has never fired (i.e.
        // it's actually shadowing it); otherwise it's a benign redundancy.
        let hotkeyDead = (status?.hotkeyEnabled ?? true) && !(status?.hotkeyReceived ?? false)
        let binds = configBindings()
        for b in binds {
            if hotkeyDead {
                bad("launcher binding shadowing your hotkey — \(b.file):\(b.line)  \(b.text)")
            } else {
                warn("redundant launcher binding — \(b.file):\(b.line)  \(b.text)")
            }
        }
        if hotkeyDead, let b = binds.first {
            problems.append("Remove the pounce-launcher binding in \(b.file) so the daemon's own "
                            + "hotkey receives the key (e.g. `skhd --stop-service`, or delete the line).")
        }
        if binds.isEmpty, !daemons.isEmpty, hotkeyDead {
            note("no launcher binding found in the usual configs — check the running "
                 + "tool's own settings for whatever is bound to \(combo)")
        }

        out.append(lines.joined(separator: "\n"))
        out.append("")

        let healthy = problems.isEmpty
        if healthy {
            out.append("\u{25B6} Healthy. \(combo) reaches pounce's fast in-process path.")
        } else {
            out.append("\u{25B6} Likely issue\(problems.count == 1 ? "" : "s"):")
            for p in problems { out.append("  \u{2022} \(p)") }
        }

        // The structured half. Everything a daemon alone can answer is null when
        // no daemon answered — an absent grant and an absent daemon are
        // different faults, and a `false` here would merge them.
        let daemon: [String: Any] = [
            "running": status != nil,
            "version": Json.value(status?.version),
            "accessibility": Json.value(status?.accessibility),
        ]
        let hotkey: [String: Any] = [
            "combo": combo,
            "enabled": Json.value(status?.hotkeyEnabled),
            "registered": Json.value(status?.hotkeyRegistered),
            // The crux of the whole command: registered but never received is
            // what an external hotkey daemon shadowing the key looks like.
            "received": Json.value(status?.hotkeyReceived),
            "bindings": status?.bindings ?? [],
        ]
        return Report(text: out.joined(separator: "\n"), healthy: healthy,
                      checks: checks, problems: problems, combo: combo,
                      daemon: daemon, hotkey: hotkey)
    }

    // MARK: Daemon query

    // Ask the running daemon for its live state (STATUS verb, JSON reply). Returns
    // nil if the daemon isn't listening.
    private static func queryDaemon() -> Status? {
        guard let reply = Daemon.request("STATUS\n"),
              let obj = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        else { return nil }
        return Status(
            version: obj["version"] as? String ?? "?",
            accessibility: obj["accessibility"] as? Bool ?? false,
            hotkeyEnabled: obj["hotkeyEnabled"] as? Bool ?? false,
            hotkeyCombo: obj["hotkeyCombo"] as? String ?? "",
            hotkeyRegistered: obj["hotkeyRegistered"] as? Bool ?? false,
            hotkeyReceived: obj["hotkeyReceived"] as? Bool ?? false,
            bindings: obj["bindings"] as? [String] ?? [])
    }

    // MARK: Environment probes

    // Running processes that grab global hotkeys via their own event tap (which
    // sits ahead of Carbon's RegisterEventHotKey, so they win the key). Name →
    // pgrep pattern; report the friendly names found.
    private static func runningHotkeyDaemons() -> [String] {
        let probes: [(name: String, pattern: String)] = [
            ("skhd", "skhd"),
            ("AeroSpace", "AeroSpace"),
            ("Raycast", "Raycast"),
            ("Karabiner-Elements", "karabiner"),
            ("Hammerspoon", "Hammerspoon"),
            ("BetterTouchTool", "BetterTouchTool"),
            ("Keyboard Maestro", "Keyboard Maestro"),
        ]
        return probes.filter { pgrepMatches($0.pattern) }.map(\.name)
    }

    private static func pgrepMatches(_ pattern: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-i", "-f", pattern]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // System Settings → Keyboard → "Press 🌐 key to". Unset means the macOS
    // default, which on a Mac with a Globe key is NOT "Do Nothing" — so a nil
    // read is a warning, not a pass.
    private static func globeKeyAction() -> Int? {
        CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                  "com.apple.HIToolbox" as CFString) as? Int
    }

    private static func globeActionName(_ value: Int?) -> String {
        switch value {
        case 1:  return "\u{201C}Change Input Source\u{201D}"
        case 2:  return "\u{201C}Show Emoji & Symbols\u{201D}"
        case 3:  return "\u{201C}Start Dictation\u{201D}"
        case nil: return "unset (macOS's default, which isn't Do Nothing)"
        default: return value.map { "set to \($0)" } ?? "unset"
        }
    }

    private struct Binding { let file: String; let line: Int; let text: String }

    // Scan the usual external-hotkey configs for a binding that runs the pounce
    // LAUNCHER — `pounce-palette` or `pounce --launcher` — the stale
    // `cmd - space : pounce-palette` class that shadows the in-process hotkey.
    // Item invocations (pounce run mode:emoji, pounce-clipboard, …) are a
    // deliberate, legitimate pattern and are NOT flagged.
    private static func configBindings() -> [Binding] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let files = [
            "\(home)/.config/skhd/skhdrc",
            "\(home)/.skhdrc",
            "\(home)/.config/aerospace/aerospace.toml",
            "\(home)/.aerospace.toml",
        ]
        var found: [Binding] = []
        for path in files {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for (i, raw) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { continue }
                if launchesPounceLauncher(line) {
                    found.append(Binding(file: prettyHome(path), line: i + 1, text: line))
                }
            }
        }
        return found
    }

    // True only for launcher invocations: pounce-palette, or `pounce … --launcher`.
    private static func launchesPounceLauncher(_ line: String) -> Bool {
        let l = line.lowercased()
        if l.contains("pounce-palette") { return true }
        if l.contains("pounce") && l.contains("--launcher") { return true }
        return false
    }

    private static func prettyHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
