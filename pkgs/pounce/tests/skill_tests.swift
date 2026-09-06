import Foundation

// `pounce skill` (Skill.swift): the two decisions that must not be got wrong on
// somebody else's Mac.
//
// The first is the trailing newline. The skill is embedded as a raw multiline
// literal, and Swift's multiline form does not include the newline before its
// closing delimiter — so the generated global is the file minus one byte, and
// `Skill.markdown` puts it back. That single byte is what makes `skill install`
// write a file byte-identical to the one `pkgs/pounce-skill` installs, which is
// in turn what lets "is this already the skill?" be answered by comparison
// rather than by guessing. Get it wrong and every re-run reports "exists and
// differs" against a file it wrote itself.
//
// The second is the install decision. It runs against directories the user did
// not create for us — a haus machine's are read-only Nix symlinks, and an
// edited skill is the user's file — so it is a pure function over three facts,
// tested here rather than discovered in someone's home directory.

func runSkillTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // ── the embedded bytes ──────────────────────────────────────────────────
    // The stub in run.sh deliberately has NO trailing newline, which is the
    // shape the generator really produces.
    check(Skill.markdown.hasSuffix("\n"),
          "Skill.markdown must end in a newline, or the installed file loses the file's last byte")
    check(!Skill.markdown.hasSuffix("\n\n"),
          "Skill.markdown must not gain a second newline — the installed copy would differ from the packaged one")
    check(Skill.markdown.hasPrefix("---\n"),
          "Skill.markdown must start with the YAML frontmatter every client routes on")

    // ── the install decision ────────────────────────────────────────────────
    check(Skill.decide(exists: false, isSymlink: false, identical: false) == .wrote,
          "nothing there → write it")
    check(Skill.decide(exists: true, isSymlink: false, identical: true) == .current,
          "already the same bytes → leave it alone, and that is not a failure")
    check(Skill.decide(exists: true, isSymlink: false, identical: false) == .differs,
          "an edited skill is the user's file — never clobber it")
    // A symlink wins over everything, INCLUDING an identical target: haus's copy
    // being current today says nothing about our right to write through it.
    check(Skill.decide(exists: true, isSymlink: true, identical: true) == .managed,
          "a symlink is somebody else's to manage, even when it currently matches")
    check(Skill.decide(exists: false, isSymlink: true, identical: false) == .managed,
          "a dangling symlink is still not ours to replace")

    // ── what the receipt's `installed` means ────────────────────────────────
    check(Skill.installed([.wrote]), "a write is a success")
    check(Skill.installed([.current]), "already-installed is a success — there is nothing to retry")
    check(Skill.installed([.managed, .wrote]), "one destination taking it is enough")
    check(Skill.installed([.managed, .managed]),
          "every destination managed by something else is the end state holding — the skill IS at those paths")
    check(!Skill.installed([.differs]), "a refusal to clobber is a refusal")
    check(!Skill.installed([]), "no destination at all is not an install")

    // ── what the exit code turns on ─────────────────────────────────────────
    // A3 of the family standard: a file left alone because it differs is the
    // request only partly honoured, and exits pounce's own refused code; a
    // symlink is the end state holding and never reaches the exit code.
    check(Skill.exitCode([.wrote], failures: 0) == 0, "a write exits 0")
    check(Skill.exitCode([.current, .current], failures: 0) == 0, "installing twice exits 0")
    check(Skill.exitCode([.managed, .managed], failures: 0) == 0,
          "only symlinks is exit 0 — a 3 here has every agent on a haus machine retry with force")
    check(Skill.exitCode([.wrote, .differs], failures: 0) == 3,
          "one destination that differs is the request only partly honoured: 3, refused")
    check(Skill.exitCode([.differs], failures: 0) == 3, "a refusal to clobber is 3")
    check(Skill.exitCode([.wrote], failures: 1) == 1,
          "a write pounce attempted and could not do is 1, not 3 — it has a path to fix")
    check(Skill.exitCode([.differs], failures: 1) == 1,
          "and a failure outranks a refusal, because it is the one with a next move")

    // ── the install request ─────────────────────────────────────────────────
    // The three refusals A3 names, pinned as a pure parse so they never need a
    // home directory to prove.
    check(Skill.parseInstall([]) == .at(dir: nil, client: nil), "no flags is discovery")
    check(Skill.parseInstall(["--dir", "/x"]) == .at(dir: "/x", client: nil), "--dir is verbatim")
    check(Skill.parseInstall(["--client", "codex"]) == .at(dir: nil, client: "codex"), "--client is one name")
    check(Skill.parseInstall(["--dir", ""]) == .refused("--dir needs a path"),
          "an empty --dir is an unset shell variable, not a path")
    check(Skill.parseInstall(["--dir"]) == .refused("--dir needs a path"),
          "a --dir with nothing after it says so")
    func refusal(_ args: [String]) -> String? {
        if case let .refused(message) = Skill.parseInstall(args) { return message }
        return nil
    }
    check(refusal(["--client", ""])?.hasPrefix("--client needs one of") == true,
          "an empty --client is refused, and names the clients")
    check(refusal(["--client"])?.hasPrefix("--client needs one of") == true,
          "a --client with nothing after it says so")
    check(refusal(["--dir", "/x", "--client", "claude"])?.contains("both name a destination") == true,
          "--dir and --client together are two answers to where — refused, not ranked")
    check(refusal(["--client", "claude", "--dir", "/x"])?.contains("both name a destination") == true,
          "in either order")
    check(refusal(["--into", "/x"])?.contains("unknown flag '--into'") == true,
          "an unknown flag is named")

    // ── the haus sentence ───────────────────────────────────────────────────
    // The whole point of naming haus here is that an EPERM explains nothing.
    let hausMessage = Skill.sentence(.managed, dest: "/Users/x/.claude/skills/pounce/SKILL.md",
                                     linkTarget: "/nix/store/abc-pounce-skill/pounce/SKILL.md")
    check(hausMessage.contains("haus"),
          "a Nix-store symlink must name haus, not leave the user to work it out")
    let otherMessage = Skill.sentence(.managed, dest: "/Users/x/.claude/skills/pounce/SKILL.md",
                                      linkTarget: "/Users/x/dotfiles/pounce.md")
    check(!otherMessage.contains("haus"),
          "a symlink that is not a store path must not blame haus for it")

    // ── the client table ────────────────────────────────────────────────────
    // Every client we advertise has to resolve, or `--client <name>` fails on a
    // name `--help` told the user to type.
    for client in Skill.clients {
        check(Skill.skillsDir(client: client, home: "/home/x") != nil,
              "\(client) is advertised but has no skills directory")
    }
    check(Skill.skillsDir(client: "emacs", home: "/home/x") == nil,
          "an unknown client must not resolve to a directory")
    check(Skill.skillsDir(client: "claude", home: "/home/x") == "/home/x/.claude/skills",
          "claude's skills directory moved — every install would land where nothing reads")

    if failures == 0 { print("ok — all `pounce skill` tests passed") }
    return failures
}
