import Foundation

func runCommandRegistryTests() -> Int {
    var failed = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed += 1
        }
    }

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "pounce-command-registry-\(UUID().uuidString)",
        isDirectory: true)
    let builtin = root.appendingPathComponent("builtin", isDirectory: true)
    let config = root.appendingPathComponent("config", isDirectory: true)

    do {
        try fm.createDirectory(at: builtin, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: config.appendingPathComponent("pounce/commands", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        #!/bin/bash
        # pounce: name = Popular Apps
        # pounce: description = Pick an application
        # pounce: icon = app.badge
        # pounce: submenu = true
        """.write(to: builtin.appendingPathComponent("popular-apps.sh"),
                  atomically: true, encoding: .utf8)
        try "Safari\tcom.apple.Safari\n".write(
            to: builtin.appendingPathComponent("popular-apps.tsv"),
            atomically: true, encoding: .utf8)
        try "not a command\n".write(
            to: builtin.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try "#!/bin/bash\n".write(
            to: builtin.appendingPathComponent("fallback.sh"),
            atomically: true, encoding: .utf8)

        let registry = CommandRegistry(
            env: [
                "POUNCE_BUILTIN_DIR": builtin.path,
                "XDG_CONFIG_HOME": config.path,
            ],
            home: root.path)
        registry.refresh()

        check(registry.entries.map(\.id) == ["fallback", "popular-apps"],
              "only .sh files in command directories are registered")
        check(registry.entries.first(where: { $0.id == "popular-apps" })?.name == "Popular Apps",
              "a .sh command still reads its metadata")
        check(registry.entries.first(where: { $0.id == "popular-apps" })?.submenu == true,
              "a .sh command keeps submenu metadata")
        check(registry.entries.first(where: { $0.id == "fallback" })?.name == "fallback",
              "a headerless .sh command still falls back to its filename")
        check(registry.scriptPath(for: "popular-apps.tsv") == nil,
              "support data cannot be resolved as a runnable command")

        // `whenFile`: the named file is a veto, and only a literal `0` vetoes.
        // Every "nobody is answering" shape has to LIST the row — a row that
        // hides when its producer is missing hides forever, with no diagnostic.
        let state = root.appendingPathComponent("state", isDirectory: true)
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        func writeState(_ name: String, _ contents: String) throws {
            try contents.write(to: state.appendingPathComponent(name),
                               atomically: true, encoding: .utf8)
        }
        try writeState("yes", "1\n")
        try writeState("no", "0\n")
        try writeState("empty", "")
        try writeState("noisy", "0 but with more on the line\n")
        for (id, file) in [("listed", "yes"), ("vetoed", "no"), ("blank", "empty"),
                           ("noisy", "noisy"), ("absent", "not-written-yet")] {
            try """
            #!/bin/bash
            # pounce: name = \(id)
            # pounce: whenFile = \(state.appendingPathComponent(file).path)
            """.write(to: builtin.appendingPathComponent("\(id).sh"),
                      atomically: true, encoding: .utf8)
        }
        registry.refresh()
        let listedIDs = Set(registry.entries.map(\.id))
        check(listedIDs.contains("listed"), "a whenFile saying 1 lists the row")
        check(!listedIDs.contains("vetoed"), "a whenFile saying 0 hides the row")
        check(listedIDs.contains("blank"), "an empty whenFile lists the row")
        check(listedIDs.contains("noisy"), "only a bare 0 vetoes, not a line starting with one")
        check(listedIDs.contains("absent"), "a whenFile that does not exist lists the row")
        check(registry.scriptPath(for: "vetoed") != nil,
              "a vetoed row is still runnable by id, the way enabled:false leaves a key armed")

        // The veto is re-read on every refresh, not cached with the header: the
        // script has not changed, the world has.
        try writeState("no", "1\n")
        try writeState("yes", "0\n")
        registry.refresh()
        let afterFlip = Set(registry.entries.map(\.id))
        check(afterFlip.contains("vetoed") && !afterFlip.contains("listed"),
              "flipping the files flips the rows without touching the scripts")

        check(CommandRegistry.expandTilde("~/x", home: "/home/me") == "/home/me/x",
              "a leading ~ in whenFile expands to home")
        check(CommandRegistry.expandTilde("/tmp/~x", home: "/home/me") == "/tmp/~x",
              "a ~ anywhere else is left alone")

        // ── the three declarations (CommandRisk) ─────────────────────────────
        // The grammar itself is pinned by the golden table below, in both
        // parsers at once. What is pinned HERE is the rest of the round trip:
        // the flags reach the Entry, they survive the registry line, and they
        // come back out of it as the same three booleans. That line is the only
        // channel between the parser and the row for two of pounce's three
        // launcher paths, so a field lost in it is a confirm sheet that never
        // opens with nothing else to see.
        try """
        #!/bin/bash
        # pounce: name = Risky
        # pounce: description = Does something
        # pounce: mutates = true
        # pounce: confirm = 1
        """.write(to: builtin.appendingPathComponent("risky.sh"),
                  atomically: true, encoding: .utf8)
        registry.refresh()
        guard let risky = registry.entries.first(where: { $0.id == "risky" }) else {
            check(false, "a command declaring mutates/confirm is registered at all")
            return failed
        }
        check(risky.risk.mutates, "mutates = true is read")
        check(risky.risk.confirm, "confirm = 1 is true, the same spelling submenu takes")
        check(!risky.risk.network, "a key the header never names is false, not unknown")
        check(risky.risk.declared == ["mutates", "confirm"],
              "declared() names the true keys in header order")
        check(registry.entries.first(where: { $0.id == "fallback" })?.risk.isEmpty == true,
              "a command that declares nothing declares nothing")

        let round = PounceItem.parseCommand(risky.registryLine)
        check(round.risk == risky.risk,
              "the declarations survive the registry line the launcher is handed")
        check(round.payload == "risky" && round.title == "Risky" && !round.submenu,
              "…and the fields that were already on that line still land where they did")

        // The four-field line every pounce-palette wrote before these keys
        // existed. It has to keep parsing, as a command that declares nothing —
        // a `pounce` newer than the launcher script beside it is the ordinary
        // state of a half-updated install.
        let legacy = PounceItem.parseCommand("Old\tdesc\tstar\told\t1")
        check(legacy.submenu && legacy.risk.isEmpty,
              "a registry line with no flag fields is a command that declares nothing")

        // `pounce list --json`, and the daemon's COMMANDS reply — one builder,
        // so the two can never describe the same command differently.
        let record = risky.jsonRecord
        check(record["key"] as? String == "cmd:risky",
              "a record is keyed the way `pounce run` and config.json's items map address it")
        check(record["mutates"] as? Bool == true && record["confirm"] as? Bool == true
                && record["network"] as? Bool == false,
              "the record carries all three declarations, including the false one")
        check(record["path"] as? String == risky.scriptPath,
              "…and the path, because the declaration is a claim and the script is the evidence")

        // ── the header-grammar golden table ──────────────────────────────────
        // Three parsers read this grammar and no two are the same language (see
        // tests/fixtures/README.md); they cannot be collapsed, because haus
        // parses headers at Nix EVAL time where calling a pounce binary would be
        // IFD on every rebuild. So each is pinned to one table instead, and the
        // fixtures are shared files rather than inline strings precisely so this
        // test and the pounce-palette harness cannot drift into testing two
        // different grammars.
        //
        // `registryLine` is the comparison surface because it is already the
        // exact TSV the awk emits — so "the two parsers agree" needs no mapping
        // layer that could itself be wrong.
        let fixtures = ProcessInfo.processInfo.environment["POUNCE_TEST_FIXTURES"]
            ?? "tests/fixtures"
        let grammarDir = fixtures + "/header-grammar"
        let grammarTable = fixtures + "/header-grammar.tsv"
        if let expected = try? String(contentsOfFile: grammarTable, encoding: .utf8) {
            // `whenFile`'s two fixtures name `~/state/{yes,no}`, so the tilde has
            // to land somewhere this test owns — which also pins that both
            // parsers expand `~` against the same HOME.
            let ghome = root.appendingPathComponent("grammar-home", isDirectory: true)
            try fm.createDirectory(at: ghome.appendingPathComponent("state", isDirectory: true),
                                   withIntermediateDirectories: true)
            try "1\n".write(to: ghome.appendingPathComponent("state/yes"),
                            atomically: true, encoding: .utf8)
            try "0\n".write(to: ghome.appendingPathComponent("state/no"),
                            atomically: true, encoding: .utf8)
            let empty = root.appendingPathComponent("grammar-empty-config", isDirectory: true)
            try fm.createDirectory(at: empty, withIntermediateDirectories: true)

            let grammar = CommandRegistry(
                env: ["POUNCE_BUILTIN_DIR": grammarDir, "XDG_CONFIG_HOME": empty.path],
                home: ghome.path)
            grammar.refresh()
            let actual = grammar.entries.map(\.registryLine).joined(separator: "\n") + "\n"
            check(actual == expected,
                  "the daemon's header parser no longer produces \(grammarTable).\n"
                  + "--- expected ---\n\(expected)--- actual ---\n\(actual)")
        } else {
            check(false, "header-grammar fixtures are missing (looked in \(fixtures)) — "
                       + "restore them rather than deleting this check: a header a "
                       + "parser silently ignores has no other symptom.")
        }
    } catch {
        check(false, "command registry fixture setup succeeds: \(error)")
    }

    if failed == 0 { print("ok — all CommandRegistry tests passed") }
    return failed
}
