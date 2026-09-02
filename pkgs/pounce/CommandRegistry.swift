import Foundation

// MARK: - Command discovery (daemon-side)

// Owns command discovery so the in-process launcher never shells out. The bash
// launcher (pounce-palette) rebuilt this on *every* ⌘Space — a mktemp, a dozen
// symlinks, and an awk fork per command — to produce a byte-identical registry
// each time. Here the daemon scans the same directories once and re-reads a
// script only when its mtime changes (a stat, not a subprocess), then spawns the
// selected script itself with no client round-trip.
//
// Discovery order mirrors pounce-palette exactly (later shadows earlier by id):
//   POUNCE_BUILTIN_DIR
//   POUNCE_EXTRA_COMMAND_DIRS   (colon-separated)
//   POUNCE_COMMAND_PATH         (colon-separated)
//   ~/.config/pounce/commands
//
// The daemon reads these from its OWN environment, so the launch agent that
// starts the daemon must export the same values the pounce-palette wrapper does
// (see haus/modules/pounce). Missing dirs are simply skipped.
// MARK: - What a command declares about itself

// Three booleans a command's own `# pounce:` header can carry — `mutates`,
// `confirm`, `network` — so the palette can say what a script does BEFORE it
// runs one. A command is a file, usually someone else's; the row you see says
// only its name, and until now the only way to learn what it did was to read it
// or to run it.
//
// It is a DECLARATION, not a sandbox: nothing here stops a command doing
// anything, exactly as nothing checks that `icon` suits it. That bargain is
// worth making because an author who declares nothing and an author who lies
// are different things — the first is the norm and reads as "unknown", the
// second is a claim you can hold them to.
//
//   mutates   changes something outside pounce that outlives the palette
//   confirm   the palette asks before running it — the one key with teeth
//   network   it talks to the internet
//
// `confirm` gates the palette's invocation of the SCRIPT, which for a `submenu`
// command means asking before its picker opens. That is rarely what a two-step
// command wants (its first step only draws a list); the step that acts is a
// second `pounce` invocation the daemon cannot tell apart from any other, so a
// submenu that wants a confirmation asks for one itself.
struct CommandRisk: Equatable {
    var mutates = false
    var confirm = false
    var network = false

    static let none = CommandRisk()
    var isEmpty: Bool { self == .none }

    /// The keys that are true, in the order the header documents them — the
    /// declaration column of `pounce list`, and what the confirm sheet reads.
    var declared: [String] {
        var out: [String] = []
        if mutates { out.append("mutates") }
        if confirm { out.append("confirm") }
        if network { out.append("network") }
        return out
    }
}

final class CommandRegistry {
    struct Entry {
        let id: String
        let name: String
        let description: String
        let icon: String
        let submenu: Bool
        // What the header says this command will do. It rides the registry LINE
        // rather than being looked up at commit time because the launcher is
        // presented by three paths (the in-process hotkey, the socket client,
        // the no-daemon fallback) and only the first of them can see THIS
        // object — the other two are handed the lines by pounce-palette's awk.
        let risk: CommandRisk
        let scriptPath: String

        // The tab-separated line the launcher parses (PounceItem.parseCommand):
        //   name \t description \t icon \t id \t submenu \t mutates \t confirm \t network
        // (every flag 1|0). Appended to, never reordered: the five leading
        // fields are what the shell launcher has always emitted, and
        // parseCommand reads each of the trailing flags only if it is there —
        // so a registry line from an older pounce-palette still parses, as a
        // command that declares nothing.
        var registryLine: String {
            // Tabs stripped, because this line IS the field separator: one in a
            // header value shifts every field after it, and PounceItem
            // .parseCommand then reads the id out of the icon's column (a row
            // that draws wrong and cannot be run). The bash registry builder
            // does the same, and has to.
            func flat(_ s: String, _ replacement: String) -> String {
                s.replacingOccurrences(of: "\t", with: replacement)
            }
            func flag(_ b: Bool) -> String { b ? "1" : "0" }
            return "\(flat(name, " "))\t\(flat(description, " "))\t\(flat(icon, ""))"
                + "\t\(id)\t\(flag(submenu))"
                + "\t\(flag(risk.mutates))\t\(flag(risk.confirm))\t\(flag(risk.network))"
        }

        /// One command as a JSON record — what `pounce list --json` prints and
        /// what the daemon's COMMANDS reply carries, so the two can never
        /// describe the same command differently. `path` is here because the
        /// declarations are a claim and the script is the evidence: a reader who
        /// wants to know what a command really does needs somewhere to look.
        var jsonRecord: [String: Any] {
            [
                "key": "cmd:\(id)",
                "id": id,
                "name": name,
                "description": description,
                "icon": icon,
                "submenu": submenu,
                "mutates": risk.mutates,
                "confirm": risk.confirm,
                "network": risk.network,
                "path": scriptPath,
            ]
        }
    }

    private struct Header {
        var name = ""
        var description = ""
        var icon = ""
        var submenu: Bool? = nil
        var whenFile = ""
        var mutates: Bool? = nil
        var confirm: Bool? = nil
        var network: Bool? = nil
    }

    private let env: [String: String]
    private let home: String

    // scriptPath → (mtime, parsed header), so an unchanged file is never re-read.
    private var headerCache: [String: (mtime: TimeInterval, header: Header)] = [:]

    // Result of the last refresh(): entries in id order, plus the id→path map the
    // spawner uses on selection.
    private(set) var entries: [Entry] = []
    private var scriptByID: [String: String] = [:]

    // Every command that declares a `whenFile`, and what that file said on the
    // last refresh. Nothing in the palette reads this — `pounce doctor` does. A
    // vetoed row is indistinguishable from a row you never installed, so the
    // report is the only place that can name it (the same reason the `items`
    // scoping is reported there; see Doctor.swift).
    private(set) var scopes: [(id: String, whenFile: String, listed: Bool)] = []

    init(env: [String: String] = ProcessInfo.processInfo.environment,
         home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.env = env
        self.home = home
    }

    func scriptPath(for id: String) -> String? { scriptByID[id] }

    // Re-resolve the id→script map and (re)parse changed headers. Cheap enough to
    // call on every hotkey press: it lists a handful of dirs and stats a dozen
    // files; only genuinely-changed scripts are re-read.
    func refresh() {
        var resolved: [String: String] = [:]   // id → path (later dir wins)
        for dir in searchDirs() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() {
                // Command directories may also hold data consumed by submenu
                // scripts. Only .sh files are commands; otherwise resources
                // such as popular-apps.tsv become bogus top-level entries and
                // are later handed to bash if selected.
                guard name.hasSuffix(".sh") else { continue }
                let path = dir + "/" + name
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue
                else { continue }
                let id = idFromFilename(name)
                resolved[id] = path   // later dir in the search order shadows earlier
            }
        }

        var built: [Entry] = []
        var scoped: [(id: String, whenFile: String, listed: Bool)] = []
        for id in resolved.keys.sorted() {
            let path = resolved[id]!
            let header = header(forScriptAt: path)
            // Asked ONCE. Two calls would let a file that flips between them
            // leave `scopes` reporting the opposite of what the palette drew.
            let listed = Self.listed(whenFile: header.whenFile, home: home)
            if !header.whenFile.isEmpty {
                scoped.append((id, header.whenFile, listed))
            }
            // `whenFile` scopes the ROW, so a vetoed command is left out of
            // `entries` and kept in `scriptByID`: `pounce run cmd:<id>` and any
            // hotkey on the item still work, exactly as `enabled: false` leaves a
            // key armed (ItemSettings.swift).
            guard listed else { continue }
            built.append(Entry(
                id: id,
                name: header.name.isEmpty ? id : header.name,
                description: header.description,
                icon: header.icon.isEmpty ? "sparkles" : header.icon,
                submenu: header.submenu ?? false,
                risk: CommandRisk(mutates: header.mutates ?? false,
                                  confirm: header.confirm ?? false,
                                  network: header.network ?? false),
                scriptPath: path))
        }

        entries = built
        scriptByID = resolved
        scopes = scoped
        // Drop cache entries for scripts that no longer resolve.
        let live = Set(resolved.values)
        headerCache = headerCache.filter { live.contains($0.key) }
    }

    // MARK: - Internals

    private func searchDirs() -> [String] {
        var dirs: [String] = []
        // The built-in set. A packager's launch agent is expected to export
        // POUNCE_BUILTIN_DIR (haus does); when it doesn't — notably the
        // Homebrew launchd service, which only sets LANG — fall back to the same
        // default pounce-palette uses (<prefix>/share/pounce/commands, derived
        // from the executable). Without this the in-process launcher finds zero
        // built-ins (Emoji, Clipboard, Find Files, …) while apps still list,
        // since AppScanner needs no environment. Missing dirs are skipped later.
        if let builtin = env["POUNCE_BUILTIN_DIR"], !builtin.isEmpty {
            dirs.append(builtin)
        } else if let fallback = Self.defaultBuiltinDir() {
            dirs.append(fallback)
        }
        for key in ["POUNCE_EXTRA_COMMAND_DIRS", "POUNCE_COMMAND_PATH"] {
            if let value = env[key], !value.isEmpty {
                dirs.append(contentsOf: value.split(separator: ":").map(String.init))
            }
        }
        let configHome = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (home + "/.config")
        dirs.append(configHome + "/pounce/commands")
        return dirs
    }

    // The built-in command dir relative to the running binary, for launchers
    // that don't export POUNCE_BUILTIN_DIR. Mirrors pounce-palette's
    // `<script dir>/../share/pounce/commands` default. The daemon runs as the
    // bundle executable (<prefix>/Pounce.app/Contents/MacOS/pounce), so the
    // keg's share dir is four components up; a plain `<prefix>/bin/pounce`
    // layout is one deletion shallower — try both, return the first that exists.
    //
    // Last resort: the copy build.sh bakes into the app bundle itself
    // (Contents/Resources/commands). That is what keeps a Pounce.app dragged
    // straight to /Applications from a release download working: there is no
    // keg and no launch agent to export anything, so without the in-bundle copy
    // the palette would list apps and zero built-ins. Deliberately LAST so any
    // packager-managed dir (which the user may have patched) shadows it.
    private static func defaultBuiltinDir() -> String? {
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates = [
                exe.deletingLastPathComponent()   // …/Contents/MacOS
                   .deletingLastPathComponent()   // …/Contents
                   .deletingLastPathComponent()   // …/Pounce.app
                   .deletingLastPathComponent()   // <prefix>
                   .appendingPathComponent("share/pounce/commands"),
                exe.deletingLastPathComponent()   // …/bin
                   .deletingLastPathComponent()   // <prefix>
                   .appendingPathComponent("share/pounce/commands"),
            ]
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("commands") {
            candidates.append(bundled)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    // Whether the binary-relative fallback finds anything — `pounce doctor` asks,
    // to tell "no scoped rows" from "no commands visible from this shell".
    static var defaultBuiltinDirExists: Bool { defaultBuiltinDir() != nil }

    private func idFromFilename(_ name: String) -> String {
        String(name.dropLast(3))
    }

    private func header(forScriptAt path: String) -> Header {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? 0
        if let cached = headerCache[path], cached.mtime == mtime { return cached.header }
        let parsed = parseHeader(at: path)
        headerCache[path] = (mtime, parsed)
        return parsed
    }

    // Read the `# pounce: key = value` header. Headers live at the top of the
    // file, so we stop after the first 30 lines rather than slurping whole
    // scripts — the same bound the awk in pounce-palette used.
    private func parseHeader(at path: String) -> Header {
        var header = Header()
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return header }
        var seen = 0
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            seen += 1
            if seen > 30 { break }
            guard let value = headerBody(of: line, tag: "pounce:") else { continue }
            if let v = field(value, "name"), header.name.isEmpty { header.name = v }
            else if let v = field(value, "description"), header.description.isEmpty { header.description = v }
            else if let v = field(value, "icon"), header.icon.isEmpty { header.icon = v }
            // `submenu == nil`, matching the `isEmpty` guards on its string
            // siblings and the awk's `&& s == ""`: FIRST wins. Without the
            // guard a repeated key was last-wins here and first-wins there, so
            // two `submenu` lines gave the daemon a submenu and the launcher a
            // leaf — the trailing-space bug's shape, one field over.
            else if let v = field(value, "submenu"), header.submenu == nil {
                header.submenu = Self.isTrue(v)
            }
            else if let v = field(value, "whenFile"), header.whenFile.isEmpty { header.whenFile = v }
            // The three declarations (CommandRisk). Same `== nil` first-wins
            // guard and the same "true"/"1" grammar as `submenu`, for the
            // reason written above it: a repeated key that is first-wins in the
            // awk and last-wins here is one command behaving two ways, and
            // `confirm` is the field where that difference is a sheet the user
            // does or doesn't get.
            else if let v = field(value, "mutates"), header.mutates == nil {
                header.mutates = Self.isTrue(v)
            }
            else if let v = field(value, "confirm"), header.confirm == nil {
                header.confirm = Self.isTrue(v)
            }
            else if let v = field(value, "network"), header.network == nil {
                header.network = Self.isTrue(v)
            }
        }
        return header
    }

    // The boolean grammar of the header, in one place: `true` or `1`, and
    // nothing else. Anything else — `yes`, `TRUE`, a typo — is false, which is
    // deliberate for `confirm`: a header that misspells its own value must not
    // read as "asked for a confirmation" on one path and "didn't" on the other,
    // and awk's test is this exact pair.
    static func isTrue(_ value: String) -> Bool { value == "true" || value == "1" }

    // A comment line opening `#` + whitespace + `tag`, returning what follows it.
    // Tolerant of indentation and of extra space after the `#`, to match the awk
    // in pounce-palette and the Nix regex in haus — all three are pinned to
    // tests/fixtures/header-grammar.tsv, which is the only thing keeping three
    // hand-mirrored copies of one grammar honest.
    //
    // The whitespace after `#` is REQUIRED, not optional: `#pounce:` has never
    // parsed anywhere, and accepting it here would widen the grammar rather than
    // converge it. The `tight-hash` fixture pins that decision.
    private func headerBody(of line: Substring, tag: String) -> Substring? {
        let leading = line.drop { $0 == " " || $0 == "\t" }
        guard leading.first == "#" else { return nil }
        let afterHash = leading.dropFirst()
        let rest = afterHash.drop { $0 == " " || $0 == "\t" }
        // Index identity rather than `count`: "at least one space was dropped",
        // in O(1), on a path that runs per line, per script, on every ⌘Space.
        guard rest.startIndex != afterHash.startIndex, rest.hasPrefix(tag) else { return nil }
        return rest.dropFirst(tag.count)
    }

    // MARK: - `whenFile`: a row that is listed only while there is something to
    // act on.
    //
    // The question `workspaces` / `bundleIds` cannot ask is not "where are you"
    // but "is there anything here at all" — a pages picker on a Mac with no page
    // on it, a lane picker with no lanes. The answer is not in any name, so it
    // has to come from outside; what it must NOT come from is a subprocess.
    // `refresh()` runs synchronously inside `presentLauncher` on every ⌘Space,
    // and the whole build phase is ~35 ms today: one `aerospace` fork would be
    // ~15 ms of that, on the keystroke, forever, for a row that is usually
    // listed anyway. So a command names a FILE that some hook of yours already
    // maintains — the same shape `pages.mruFile` has, for the same reason — and
    // this reads it. It is a stat and at most 64 bytes.
    //
    // The file is a VETO and only a literal `0` vetoes: no file, an unreadable
    // one, an empty one (which is what a truncating writer looks like for an
    // instant) and any other content all LIST the row. A row that hides when
    // nobody is answering hides forever, with nothing in any log — the trap
    // `workspaces` avoids by filtering nothing without an `mruFile`, and the one
    // thing every mechanism on this path has to get right.
    static func listed(whenFile: String, home: String) -> Bool {
        guard !whenFile.isEmpty else { return true }
        let path = expandTilde(whenFile, home: home)
        // A REGULAR file, and nothing else. Opening a FIFO with no writer blocks
        // in open(2) — and this runs on the main thread inside presentLauncher,
        // so the palette would simply never draw, with nothing in any log. Same
        // for a device node or a stalled mount. `stat` follows symlinks, which
        // `attributesOfItem` would not, and a symlinked state file is a
        // reasonable thing for a hook to write.
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return true }
        guard let handle = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? handle.close() }
        guard let data = (try? handle.read(upToCount: 64)) ?? nil else { return true }
        guard let text = String(data: data, encoding: .utf8) else { return true }
        let first = text.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        return first.trimmingCharacters(in: .whitespaces) != "0"
    }

    // A leading `~` only. A header is written by hand, so `~/.local/state/…` is
    // the spelling people reach for; anything richer would be a shell, and a
    // shell is what this key exists to avoid.
    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    // "key = value" → value, if `rest` names `key`. Whitespace-tolerant to match
    // the awk header parser (`# pounce: name  =  Foo`).
    //
    // Space and tab ONLY, on both sides — deliberately narrower than
    // `.trimmingCharacters(in: .whitespaces)`, which also trims U+00A0 and the
    // U+2000 block. awk's `[ \t]` cannot follow it there, and ⌥Space types a
    // non-breaking space on macOS, so trimming it here would have made
    // `submenu = true<NBSP>` a submenu in the daemon and a leaf in the shell
    // launcher — the same split this file's trailing-space fix just closed, in
    // a character you cannot see. Converged-and-narrow beats forgiving-and-split.
    private func field(_ rest: Substring, _ key: String) -> String? {
        let s = rest.drop { $0 == " " || $0 == "\t" }
        guard s.hasPrefix(key) else { return nil }
        let afterKey = s.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        guard afterKey.first == "=" else { return nil }
        let value = afterKey.dropFirst().drop { $0 == " " || $0 == "\t" }
        return String(value.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}

// MARK: - Spawning the selected command

// Runs a selected command script detached from the daemon, the way pounce-palette
// used to `exec` it. Submenu commands re-invoke `pounce` (the client), so the
// child's PATH gets this binary's directory prepended so that resolves.
enum CommandSpawner {
    static func run(scriptPath: String) {
        let process = Process()
        var environment = ProcessInfo.processInfo.environment
        let binDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        environment["PATH"] = binDir + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        // Mirror pounce-palette: exec directly when executable, else run via bash.
        if FileManager.default.isExecutableFile(atPath: scriptPath) {
            process.executableURL = URL(fileURLWithPath: scriptPath)
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
        }
        process.terminationHandler = { _ in }   // reap asynchronously; never block the daemon
        do {
            try process.run()
        } catch {
            NSLog("pounce daemon: failed to spawn command \(scriptPath): \(error)")
        }
    }
}
