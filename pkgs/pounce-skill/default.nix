# pounce's agent skill, as a derivation.
#
# The source is `ai/SKILL.md` at the repo root — one file, committed, and the
# same bytes `pounce skill` prints, because build.sh embeds that very file in
# the binary (see pkgs/pounce/build.sh). This derivation is how a *consumer*
# gets it without building pounce at all: haus takes pounce as a flake input
# already, so `pkgs.pounce-skill` is all its AI room needs in order to drop the
# skill into every agent client on the machine. A standalone user — Homebrew, a
# DMG, no haus anywhere — gets the identical bytes from `pounce skill install`.
#
# Its own package rather than a file inside `pounce`: a consumer that only wants
# the prose should not have to compile Swift and bake in a palette to get it.
# (It no longer buys *cache* independence — the app derivation reads
# ai/SKILL.md now, so a prose edit rebuilds it. That is the price of the binary
# being able to answer for itself on a Mac with no checkout, and the standard
# asks for it explicitly.)
#
# `$out/<skill>/SKILL.md` is the family standard's compliant-tool layout (the
# workshop's docs/agent-surface.md): one nesting level, named for the SKILL, so
# a consumer links a directory that is already called the right thing and the
# tool decides that name rather than whoever installs it. haus's own skill is
# flat, `$out/SKILL.md` — it predates the standard, and is the one exception
# rather than the pattern. Skill names are globally unique across the family:
# they all land in one shared `~/.claude/skills/`.
#
# Skills are DISCOVERED here, not listed. pounce ships one today; a tool that
# grows a second and packages only its first reaches no consumer with it.
{
  lib,
  runCommand,
}:

runCommand "pounce-skill"
  {
    meta = {
      description = "Agent skill teaching a coding agent to drive the pounce command palette";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }
  ''
    ai=${../../ai}

    # The guards live in a script BOTH this and CI run (script/check-skills.sh),
    # because most of what it catches is invisible at runtime — a skill with
    # broken frontmatter installs, lists and never loads — and this repo's CI
    # builds Swift on a macOS runner where a rule hidden in a Nix expression
    # would never be seen by a contributor without Nix.
    bash ${../../script/check-skills.sh} "$ai"

    for skill in "$ai"/SKILL.md "$ai"/*/SKILL.md; do
      [ -f "$skill" ] || continue
      if [ "$skill" = "$ai/SKILL.md" ]; then
        name=pounce
      else
        name="$(basename "$(dirname "$skill")")"
      fi
      mkdir -p "$out/$name"
      cp "$skill" "$out/$name/SKILL.md"
    done
  ''
