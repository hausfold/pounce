// `pounce config` — write out an annotated config.json, or say where it lives.
//
//   pounce config            print the config path
//   pounce config init       write it, with every setting at its default,
//                            documented and commented out
//   pounce config init --force   replace an existing one
//   pounce config --json     the path, and whether it is yours to edit
//   pounce config print --json   the EFFECTIVE settings — what pounce will use,
//                            plus the keys the file actually names
//
// Pounce is installable on its own (Homebrew, a drag-install), and standalone is
// the case this is FOR: inside the haus desktop the settings are written from
// `haus.launcher.*` and this file isn't yours to edit — see the guard below.

import Foundation

enum ConfigMode {
    static func run(op: String?, args: [String]) {
        let json = args.contains("--json")
        // `--json` is a flag, not a subcommand: `pounce config --json` asks
        // about the path, the same as bare `pounce config`.
        let op = (op == "--json" || op == "--force") ? nil : op
        switch op {
        case nil, "path":
            if json {
                Json.emit(location(Settings.configPath))
            } else {
                print(Settings.configPath.path)
            }
        case "init":
            initialize(force: args.contains("--force"))
        case "print":
            if json {
                // A different question from the annotated template, deliberately:
                // that file documents the DEFAULTS, this prints what pounce will
                // actually use — post-clamp, with the user's file folded in — plus
                // `set`, the keys their config.json actually names. The family
                // standard (A5) asks exactly that, so an agent can tell "unset"
                // from "set to the default" instead of guessing from a value.
                printEffective()
            } else {
                // The same text `init` writes, to stdout, touching nothing. It's how
                // you diff the template against a config you've already edited
                // (`pounce config print | diff - ~/.config/pounce/config.json`), and
                // the only way to see it at all on a Nix-managed machine, where
                // `init` correctly refuses.
                print(rendered(), terminator: "")
            }
        default:
            FileHandle.standardError.write(Data("""
            pounce config: unknown subcommand '\(op ?? "")'.

              pounce config          print the config path
              pounce config print    print an annotated config to stdout
              pounce config init     write it to the config path (--force replaces)

            Add --json to `config` or `config print` for a machine-readable answer.

            """.utf8))
            exit(2)
        }
    }

    // MARK: - `--json`

    /// Where the config is, and who owns it. Small enough to be part of every
    /// other record too — an agent's first question about a settings file is
    /// almost always "may I edit this one?", and on a haus machine the answer is
    /// no. `managed` is the one key that answers it.
    private static func location(_ path: URL) -> [String: Any] {
        [
            "path": path.path,
            "exists": FileManager.default.fileExists(atPath: path.path),
            "managed": isNixManaged(path) ? "nix" : "user",
        ]
    }

    /// The EFFECTIVE settings — every key at the value pounce will use, read back
    /// off a live `Settings.load()` through the same `ConfigSpec` table that
    /// renders the annotated template and draws the Settings window. Reusing that
    /// table rather than walking `Settings` again is what stops a fourth
    /// rendering of the same data drifting from the other three.
    private static func printEffective() {
        let settings = Settings.load()
        var effective: [String: Any] = [:]
        for section in ConfigSpec.sections(defaults: settings) {
            guard !section.fields.isEmpty else { continue }
            // ConfigSpec already rendered each value as a JSON literal for the
            // template; parse it back rather than re-deriving the type here.
            let values = Dictionary(uniqueKeysWithValues:
                section.fields.map { ($0.name, Json.parse($0.json)) })
            if let name = section.name {
                effective[name] = values
            } else {
                // Two sections sit at the top level (the appearance keys and
                // "fnKey"); they merge into one object, as they do in the file.
                effective.merge(values) { _, new in new }
            }
        }
        // `items` is the one section with no fixed key list, so ConfigSpec has no
        // fields to render for it and the loop above skips it. Left out, the
        // "effective config" would silently omit every per-item override the user
        // wrote — the half of the file most likely to be why a row behaves oddly.
        effective["items"] = settings.items.entries
            .sorted { $0.key < $1.key }
            .reduce(into: [String: Any]()) { out, entry in
                var item: [String: Any] = ["enabled": entry.value.enabled]
                item["alias"] = Json.value(entry.value.alias)
                item["hotkey"] = Json.value(entry.value.hotkey?.display)
                item["hint"] = Json.value(entry.value.hint)
                item["state"] = Json.value(entry.value.state)
                item["workspaces"] = entry.value.workspaces
                item["bundleIds"] = entry.value.bundleIds
                out[entry.key] = item
            }

        var record = location(Settings.configPath)
        record["version"] = pounceVersion
        record["settings"] = effective
        record["set"] = setKeys()
        Json.emit(record)
    }

    /// The dotted paths the user's config.json actually names, sorted. This is
    /// the whole point of `--json` over the template: a value that equals the
    /// default reads identically whether it was written down or never touched,
    /// and only the file itself can tell them apart.
    ///
    /// Read through the SAME `.json5Allowed` parser `Settings.load()` uses, so a
    /// config with comments in it — the file `config init` invites people to
    /// write — is walked rather than reported as absent. A path here that has no
    /// counterpart under `settings` is a key pounce does not know, which is worth
    /// seeing rather than hiding.
    private static func setKeys() -> [String] {
        guard let data = try? Data(contentsOf: Settings.configPath),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
                as? [String: Any]
        else { return [] }
        var out: [String] = []
        func walk(_ object: [String: Any], prefix: String) {
            for (key, value) in object {
                let path = prefix.isEmpty ? key : prefix + "." + key
                if let nested = value as? [String: Any], !nested.isEmpty {
                    walk(nested, prefix: path)
                } else {
                    out.append(path)
                }
            }
        }
        walk(obj, prefix: "")
        return out.sorted()
    }

    private static func rendered() -> String {
        do {
            return try ConfigSpec.render(version: pounceVersion)
        } catch {
            // Only reachable if the template stopped being valid JSON once its
            // comments came off — a bug in ConfigSpec, not in anyone's config.
            // Say so rather than handing out a file pounce would silently ignore.
            FileHandle.standardError.write(Data(
                "pounce config: the generated template isn't valid JSON — this is a bug, please report it.\n".utf8))
            exit(1)
        }
    }

    /// True when config.json is a symlink into the Nix store — i.e. home-manager
    /// wrote it from `haus.launcher.*`. Writing there fails (the store is
    /// read-only) and would be wrong even if it didn't: the next `haus rebuild`
    /// puts the generated file straight back, so an edit isn't lost so much as
    /// silently reverted, which is worse.
    static func isNixManaged(_ url: URL) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        else { return false }
        return target.hasPrefix("/nix/store/")
    }

    private static func initialize(force: Bool) {
        let path = Settings.configPath

        if isNixManaged(path) {
            FileHandle.standardError.write(Data("""
            \(path.path) is managed by Nix — it's a symlink into the store, written
            from your host file's `haus.launcher.*` options.

            Change it there and run `haus rebuild`; a copy written here would be
            replaced by the next rebuild without saying so.

            See https://hausfold.co/docs/pounce/config/

            """.utf8))
            // 3, not 1: pounce declined rather than tried and failed, and an
            // agent's recovery differs — there is nothing here to retry. See the
            // exit-code table in `pounce --help`.
            exit(3)
        }

        let text = rendered()

        var dest = path
        var replaced = true
        if FileManager.default.fileExists(atPath: path.path) && !force {
            // Never clobber. Once you've uncommented lines, that file is yours —
            // and the whole point of this feature is that the file accumulates
            // your decisions.
            dest = path.deletingLastPathComponent().appendingPathComponent("config.json.new")
            replaced = false
        }

        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("pounce config: couldn't write \(dest.path): \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        if replaced {
            print("Wrote \(dest.path) — every setting, at its default, commented out.")
            print("Uncomment what you want to change; delete the rest. Takes effect on the next ⌘Space.")
        } else {
            print("\(path.path) already exists, so this went to \(dest.path) instead.")
            print("Diff them and merge what you want, or re-run with --force to replace.")
        }
    }
}
