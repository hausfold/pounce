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
final class CommandRegistry {
    struct Entry {
        let id: String
        let name: String
        let description: String
        let icon: String
        let submenu: Bool
        let scriptPath: String

        // The tab-separated line the launcher parses (PounceItem.parseCommand):
        //   name \t description \t icon \t id \t submenu(1|0)
        var registryLine: String {
            // Tabs stripped, because this line IS the field separator: one in a
            // header value shifts every field after it, and PounceItem
            // .parseCommand then reads the id out of the icon's column (a row
            // that draws wrong and cannot be run). The bash registry builder
            // does the same, and has to.
            func flat(_ s: String, _ replacement: String) -> String {
                s.replacingOccurrences(of: "\t", with: replacement)
            }
            return "\(flat(name, " "))\t\(flat(description, " "))\t\(flat(icon, ""))"
                + "\t\(id)\t\(submenu ? "1" : "0")"
        }
    }

    private struct Header {
        var name = ""
        var description = ""
        var icon = ""
        var submenu = false
        var whenFile = ""
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
                submenu: header.submenu,
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
        // POUNCE_BUILTIN_DIR (the Nix rice does); when it doesn't — notably the
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
            guard let value = value(of: line, after: "pounce:") else { continue }
            if let v = field(value, "name"), header.name.isEmpty { header.name = v }
            else if let v = field(value, "description"), header.description.isEmpty { header.description = v }
            else if let v = field(value, "icon"), header.icon.isEmpty { header.icon = v }
            else if let v = field(value, "submenu") { header.submenu = (v == "true" || v == "1") }
            else if let v = field(value, "whenFile"), header.whenFile.isEmpty { header.whenFile = v }
        }
        return header
    }

    // `# <ws>+ prefix`, whitespace-tolerant before `#` and between `#` and
    // `prefix` — to match the awk parser in pounce-palette and haus's
    // `commandField`. An indented header line or a stray second space after
    // `#` used to match some of the three parsers and not the others, which a
    // hand-typed header has no way to notice.
    private func value(of line: Substring, after prefix: String) -> Substring? {
        let leading = line.drop { $0 == " " || $0 == "\t" }
        guard leading.first == "#" else { return nil }
        let afterHash = leading.dropFirst()
        let rest = afterHash.drop { $0 == " " || $0 == "\t" }
        guard rest.count < afterHash.count, rest.hasPrefix(prefix) else { return nil }
        return rest.dropFirst(prefix.count)
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
    private func field(_ rest: Substring, _ key: String) -> String? {
        let s = rest.drop { $0 == " " || $0 == "\t" }
        guard s.hasPrefix(key) else { return nil }
        let afterKey = s.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
        guard afterKey.first == "=" else { return nil }
        return afterKey.dropFirst().drop { $0 == " " || $0 == "\t" }
            .trimmingCharacters(in: .whitespaces)
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
