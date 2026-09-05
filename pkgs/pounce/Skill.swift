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
        /// Written, and only ever into empty space. There is deliberately no
        /// "replace the copy we wrote last time": nothing marks a file as ours,
        /// so the only way to tell a stale install from a deliberate edit would
        /// be to guess. The cost is that a user who installed by hand and then
        /// upgrades pounce is told the file differs, every time, until they
        /// delete it — which is what the `.differs` sentence tells them to do.
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

    /// Did any destination end up holding this skill — by pounce's hand, or by
    /// whatever manages a symlink there? The `--json` receipt's `installed`. A
    /// symlink counts: on a haus machine it is `haus.ai.skill`'s own install,
    /// and the skill IS at that path.
    static func installed(_ decisions: [Decision]) -> Bool {
        decisions.contains { $0 != .differs }
    }

    /// What the exit code turns on, and nothing else. A destination that
    /// exists and differs is the caller's request not honoured: 3, "refused",
    /// with nothing to retry. A write pounce attempted and could not do is 1
    /// instead — same "it didn't land", a completely different next move, and
    /// it wins because it is the one with a path to fix. A symlink is neither:
    /// it is the end state holding, and a non-zero there would have every
    /// agent on a haus machine report a broken command and retry with force
    /// against a store path. (A3 in the workshop's agent-surface standard.)
    static func exitCode(_ decisions: [Decision], failures: Int) -> Int32 {
        if failures > 0 { return 1 }
        if decisions.contains(.differs) { return 3 }
        return 0
    }

    // MARK: The install request

    /// Where `install` was asked to write, or why it was refused. Pure, so the
    /// three refusals can be pinned without a home directory: a flag with
    /// nothing after it; an empty value, which is an unset shell variable and
    /// not a request (let through, `--dir ""` resolves to `/pounce/SKILL.md`);
    /// and `--dir` with `--client`, two answers to "where" that must not be
    /// ranked silently in `--dir`'s favour.
    enum Request: Equatable {
        case at(dir: String?, client: String?)
        case refused(String)
    }

    static func parseInstall(_ args: [String]) -> Request {
        var dir: String?
        var client: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--dir":
                guard i + 1 < args.count, !args[i + 1].isEmpty else {
                    return .refused("--dir needs a path")
                }
                dir = args[i + 1]
                i += 2
            case "--client":
                guard i + 1 < args.count, !args[i + 1].isEmpty else {
                    return .refused("--client needs one of \(clients.joined(separator: ", "))")
                }
                client = args[i + 1]
                i += 2
            default:
                return .refused("unknown flag '\(args[i])' — install takes --client, --dir and --json")
            }
        }
        if dir != nil, client != nil {
            return .refused("--dir and --client both name a destination — pass one")
        }
        return .at(dir: dir, client: client)
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
        let request: (dir: String?, client: String?)
        switch Skill.parseInstall(args) {
        case let .at(dir, client): request = (dir, client)
        case let .refused(message): fail(message)
        }
        let dir = request.dir
        let client = request.client

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
        // A usage error naming the flag that would have answered, not a
        // refusal: nothing was declined, there was nowhere to write.
        if targets.isEmpty {
            fail("no agent client found on this Mac — name one with "
                 + "`--client \(Skill.clients.joined(separator: "|"))`, or a directory with `--dir <path>`")
        }

        var results: [[String: Any]] = []
        var decisions: [Skill.Decision] = []
        var lines: [String] = []
        // A write we believed we owned and could not do is NOT a refusal, and
        // the two want different exit codes: a refusal has nothing to retry, a
        // failure has a path to fix.
        var failures = 0

        for target in targets {
            let folder = target.dir + "/" + Skill.name
            let dest = folder + "/SKILL.md"
            // Both halves, because haus links the DIRECTORY and a hand-wired
            // host may link the file: either one means this path is not ours.
            let link = (try? fm.destinationOfSymbolicLink(atPath: folder))
                ?? (try? fm.destinationOfSymbolicLink(atPath: dest))
            // `exists` comes from the filesystem, never from whether we could
            // READ the file: `String(contentsOfFile:encoding:.utf8)` returns nil
            // for a file that is valid but not UTF-8, and treating that as
            // "nothing there" would overwrite a hand-edited skill saved in
            // another encoding — the one outcome this whole verb refuses.
            // Compared as Data for the same reason.
            let exists = fm.fileExists(atPath: dest)
            let identical = fm.contents(atPath: dest) == Data(Skill.markdown.utf8)
            let decision = Skill.decide(exists: exists,
                                        isSymlink: link != nil,
                                        identical: identical)

            if decision == .wrote {
                do {
                    try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    try Skill.markdown.write(toFile: dest, atomically: true, encoding: .utf8)
                } catch {
                    // A write we believed we owned and still could not do. Not a
                    // refusal — say what the system said.
                    let message = "could not write \(dest): \(error.localizedDescription)"
                    failures += 1
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

        if json {
            Json.emit([
                "name": Skill.name,
                "installed": Skill.installed(decisions),
                "targets": results,
            ])
        } else {
            for line in lines { print(line) }
            // The whole run was somebody else's install holding. Say that in a
            // sentence rather than leaving a list of "skipped" to read as a
            // failure: nothing was asked for that does not already exist.
            let touched = decisions.contains { $0 == .wrote || $0 == .current }
            if !touched, failures == 0, !decisions.isEmpty, !decisions.contains(.differs) {
                print("")
                print("Nothing to install: every destination is already a symlink something else manages "
                      + "(on a haus machine, haus.ai.skill). `pounce skill install --dir <path>` places a "
                      + "copy somewhere nothing else manages.")
            }
        }
        exit(Skill.exitCode(decisions, failures: failures))
    }
}
