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

    // ── what the exit code turns on ─────────────────────────────────────────
    check(Skill.installed([.wrote]), "a write is a success")
    check(Skill.installed([.current]), "already-installed is a success — there is nothing to retry")
    check(Skill.installed([.managed, .wrote]), "one destination taking it is enough")
    check(!Skill.installed([.managed, .managed]),
          "every destination managed by something else is a refusal, not a success")
    check(!Skill.installed([.differs]), "a refusal to clobber is a refusal")
    check(!Skill.installed([]), "no destination at all is not an install")

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
