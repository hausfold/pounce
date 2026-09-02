import Foundation

// MARK: - `pounce skill`
//
// The agent surface's A3 verb (the workshop's docs/agent-surface.md): print the
// skill a coding agent loads to learn these verbs, and write it into whatever
// agent clients this Mac has.
//
// Why it exists at all, given `pkgs/pounce-skill` already packages the same
// bytes: that derivation serves a CONSUMER — haus takes pounce as a flake input
// and its AI room drops the skill into every client on the machine, so a haus
// user does nothing. Most of pounce's users are not that user. They ran `brew
// install pounce`, there is no haus to install anything for them, and without
// this verb the agent on their Mac never learns pounce exists. One command is
// the whole gap.
//
// **Embedded, not read off disk.** A cask ships an .app, a Nix build ships a
// store path, a release tarball ships a folder — only embedding is uniform
// across all three, and it is what makes the version that answers `--help` the
// same version that answers `skill`. `build.sh` renders ai/SKILL.md into
// Skill.generated.swift (the `pounceSkillMarkdown` global below) with the exact
// same generator under Nix and outside it.
//
// Foundation-only, and the decisions are pure statics, so tests/run.sh can pin
// them without a home directory or a disk.

enum Skill {
    /// The skill's name — and the directory it installs into, which the standard
    /// requires to match the `name:` in the frontmatter. Skill names are globally
    /// unique across the family: every one of them lands in one shared
    /// `~/.claude/skills`, next to whatever else the user installed.
    static let name = "pounce"

    /// The clients we know how to install into, in the order they are tried.
    static let clients = ["claude", "codex", "opencode", "pi"]

    /// Where a client keeps its skills. One entry per client, written once
    /// because `install` needs the same table twice (to enumerate, and to
    /// resolve `--client`).
    static func skillsDir(client: String, home: String) -> String? {
        switch client {
        case "claude":   return home + "/.claude/skills"
        case "codex":    return home + "/.codex/skills"
        case "opencode": return home + "/.config/opencode/skills"
        case "pi":       return home + "/.pi/agent/skills"
        default:         return nil
        }
    }

    /// The exact bytes of ai/SKILL.md.
    ///
    /// The generated literal is a raw multiline string, and Swift's multiline
    /// form does not include the newline before the closing delimiter — so the
    /// global is the file minus its final newline. Restoring it here (rather
    /// than in the generator, where it would be one more thing for a
    /// non-Nix packager to get subtly wrong) is what lets `skill install` write
    /// a file byte-identical to the one `pkgs/pounce-skill` installs, which is
    /// in turn what lets `cmp` be the "already current?" test.
    static var markdown: String {
        pounceSkillMarkdown.hasSuffix("\n") ? pounceSkillMarkdown : pounceSkillMarkdown + "\n"
    }

    // MARK: The install decision

    /// What `install` did, or refused to do, at one destination.
    enum Decision: String {
        /// Written: nothing was there, or a stale copy we own was replaced.
        case wrote
        /// Already byte-identical. Not an error, and not a write.
        case current
        /// A symlink — something else manages this path. On a haus machine that
        /// something is `haus.ai.skill`, and the link points into the read-only
        /// Nix store, so writing would fail with an EPERM that explains nothing.
        case managed
        /// A real file that differs. Never clobbered: once a skill file has been
        /// edited, it is the user's.
        case differs
    }

    /// Pure so it can be tested: the three facts the filesystem supplies, and
    /// the one decision that follows from them. A symlink wins over everything
    /// because the question it answers ("is this mine to write?") comes first.
    static func decide(exists: Bool, isSymlink: Bool, identical: Bool) -> Decision {
        if isSymlink { return .managed }
        if !exists { return .wrote }
        return identical ? .current : .differs
    }

    /// The sentence for one destination. `linkTarget` is the symlink's target
    /// when there is one, so a Nix-managed path can name haus instead of leaving
    /// the user to work it out.
    static func sentence(_ decision: Decision, dest: String, linkTarget: String? = nil) -> String {
        switch decision {
        case .wrote:
            return "wrote \(dest)"
        case .current:
            return "\(dest) is already this skill — left alone"
        case .managed:
            if let linkTarget, linkTarget.hasPrefix("/nix/store/") {
                return "skipped \(dest) — it is a symlink into the Nix store, so haus already "
                    + "installs this skill (`haus.ai.skill`); a copy here would be reverted by the next rebuild"
            }
            return "skipped \(dest) — it is a symlink, so something else manages it"
        case .differs:
            return "skipped \(dest) — it exists and differs; compare with "
                + "`pounce skill | diff - \(dest)`, then delete it to take this one"
        }
    }

    /// Did any destination end up holding this skill? The exit code turns on
    /// this and nothing else: "every candidate is managed by haus" is a refusal,
    /// not a success, even though nothing went wrong.
    static func installed(_ decisions: [Decision]) -> Bool {
        decisions.contains { $0 == .wrote || $0 == .current }
    }
}

// MARK: - The CLI half

enum SkillMode {
    static func run(args: [String]) -> Never {
        var rest = args
        let json = rest.contains("--json")
        rest.removeAll { $0 == "--json" }

        switch rest.first {
        case nil, Skill.name:
            // `pounce skill` and `pounce skill pounce` are the same request. A
            // named skill is a sibling directory in the standard's layout;
            // pounce ships one, so every other name is a typo worth naming.
            guard !json else {
                Json.emit(["name": Skill.name, "markdown": Skill.markdown])
                exit(0)
            }
            print(Skill.markdown, terminator: "")
            exit(0)
        case "install":
            install(args: Array(rest.dropFirst()), json: json)
        case let other?:
            fail("no skill called '\(other)' — pounce ships one, `pounce skill`, "
                 + "and `pounce skill install` writes it where your agent will find it")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("pounce skill: \(message)\n".utf8))
        exit(2)
    }

    private static func install(args: [String], json: Bool) -> Never {
        var dir: String?
        var client: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--dir":
                guard i + 1 < args.count else { fail("--dir needs a path") }
                dir = args[i + 1]
                i += 2
            case "--client":
                guard i + 1 < args.count else {
                    fail("--client needs one of \(Skill.clients.joined(separator: ", "))")
                }
                client = args[i + 1]
                i += 2
            default:
                fail("unknown flag '\(args[i])' — install takes --client, --dir and --json")
            }
        }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        // Which directories to write into. `--dir` is verbatim; `--client` is
        // one known client; neither means every client that is actually
        // installed — judged by its PARENT existing (`~/.claude` exists, so this
        // Mac has Claude Code), because the skills dir itself is what we are
        // about to create.
        var targets: [(client: String, dir: String)] = []
        if let dir {
            targets = [(client: "", dir: dir)]
        } else if let client {
            guard let d = Skill.skillsDir(client: client, home: home) else {
                fail("unknown client '\(client)' — one of \(Skill.clients.joined(separator: ", "))")
            }
            targets = [(client: client, dir: d)]
        } else {
            for c in Skill.clients {
                guard let d = Skill.skillsDir(client: c, home: home) else { continue }
                let parent = (d as NSString).deletingLastPathComponent
                if fm.fileExists(atPath: parent) { targets.append((client: c, dir: d)) }
            }
        }

        var results: [[String: Any]] = []
        var decisions: [Skill.Decision] = []
        var lines: [String] = []

        for target in targets {
            let folder = target.dir + "/" + Skill.name
            let dest = folder + "/SKILL.md"
            // Both halves, because haus links the DIRECTORY and a hand-wired
            // host may link the file: either one means this path is not ours.
            let link = (try? fm.destinationOfSymbolicLink(atPath: folder))
                ?? (try? fm.destinationOfSymbolicLink(atPath: dest))
            let existing = try? String(contentsOfFile: dest, encoding: .utf8)
            let decision = Skill.decide(exists: existing != nil,
                                        isSymlink: link != nil,
                                        identical: existing == Skill.markdown)

            if decision == .wrote {
                do {
                    try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    try Skill.markdown.write(toFile: dest, atomically: true, encoding: .utf8)
                } catch {
                    // A write we believed we owned and still could not do. Not a
                    // refusal — say what the system said.
                    let message = "could not write \(dest): \(error.localizedDescription)"
                    if json {
                        results.append(["client": target.client, "path": dest,
                                        "decision": "failed", "message": message])
                    } else {
                        FileHandle.standardError.write(Data("pounce skill: \(message)\n".utf8))
                    }
                    continue
                }
            }

            decisions.append(decision)
            let sentence = Skill.sentence(decision, dest: dest, linkTarget: link)
            lines.append(sentence)
            results.append([
                "client": target.client,
                "path": dest,
                "decision": decision.rawValue,
                "message": sentence,
            ])
        }

        let ok = Skill.installed(decisions)
        if json {
            Json.emit([
                "name": Skill.name,
                "installed": ok,
                "targets": results,
            ])
        } else {
            if targets.isEmpty {
                FileHandle.standardError.write(Data("""
                pounce skill: no agent client found on this Mac. Name one with \
                `--client \(Skill.clients.joined(separator: "|"))`, or a directory with `--dir <path>`.

                """.utf8))
            }
            for line in lines { print(line) }
            if !ok && !targets.isEmpty {
                print("")
                print("Nothing installed — every place it would go is already spoken for. "
                      + "`pounce skill` prints it if you want to place it yourself.")
            }
        }
        // 3 is "refused": pounce declined, rather than tried and failed. An
        // agent's recovery differs — there is nothing to retry.
        exit(ok ? 0 : 3)
    }
}
