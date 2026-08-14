// `pounce config` — write out an annotated config.json, or say where it lives.
//
//   pounce config            print the config path
//   pounce config init       write it, with every setting at its default,
//                            documented and commented out
//   pounce config init --force   replace an existing one
//
// Pounce is installable on its own (Homebrew, a drag-install), and standalone is
// the case this is FOR: inside the nebelhaus rice the settings are written from
// `haus.pounce.*` and this file isn't yours to edit — see the guard below.

import Foundation

enum ConfigMode {
    static func run(op: String?, args: [String]) {
        switch op {
        case nil, "path":
            print(Settings.configPath.path)
        case "init":
            initialize(force: args.contains("--force"))
        case "print":
            // The same text `init` writes, to stdout, touching nothing. It's how
            // you diff the template against a config you've already edited
            // (`pounce config print | diff - ~/.config/pounce/config.json`), and
            // the only way to see it at all on a Nix-managed machine, where
            // `init` correctly refuses.
            print(rendered(), terminator: "")
        default:
            FileHandle.standardError.write(Data("""
            pounce config: unknown subcommand '\(op ?? "")'.

              pounce config          print the config path
              pounce config print    print an annotated config to stdout
              pounce config init     write it to the config path (--force replaces)

            """.utf8))
            exit(2)
        }
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
    /// wrote it from `haus.pounce.*`. Writing there fails (the store is
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
            from your host file's `haus.pounce.*` options.

            Change it there and run `haus rebuild`; a copy written here would be
            replaced by the next rebuild without saying so.

            See https://hausfold.co/docs/haus/reference/pounce/

            """.utf8))
            exit(1)
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
