# pounce's agent skill, as a derivation.
#
# The source is `ai/SKILL.md` at the repo root — one file, committed, the same
# one that gets embedded in the binary when `pounce skill` lands. This
# derivation is how a *consumer* gets it: haus takes pounce as a flake input
# already, so `pkgs.pounce-skill` is all its AI room needs in order to drop the
# skill into every agent client on the machine. A standalone user will get the
# identical bytes from `pounce skill install` — step 4 of the standard's
# rollout, not a verb that exists today.
#
# Its own package rather than a file inside `pounce`: the app derivation
# compiles Swift and bakes in a palette, and a sentence of prose has no business
# invalidating that.
#
# `$out/<tool>/SKILL.md` is the family standard's compliant-tool layout (the workshop's
# docs/agent-surface.md): one nesting level, named for the skill, so a
# consumer links a directory that is already called the right thing and the
# TOOL decides its skill's folder name rather than whoever installs it. haus's
# own skill is flat, `$out/SKILL.md` — it predates the standard, and is the one
# exception rather than the pattern. Skill names are globally unique across the
# family: they all land in one shared `~/.claude/skills/`.
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
    mkdir -p "$out/pounce"
    cp ${../../ai/SKILL.md} "$out/pounce/SKILL.md"

    skill="$out/pounce/SKILL.md"

    # The frontmatter, and ONLY the frontmatter. Every client routes on `name`
    # and `description`, so a header that is missing, never closed, or whose
    # keys only appear down in the body produces a skill that installs, lists,
    # and never loads — indistinguishable, from the user's side, from the agent
    # not knowing pounce exists. That is the failure worth failing a build over.
    head -1 "$skill" | grep -qx -- '---' \
      || { echo "ai/SKILL.md does not open with YAML frontmatter" >&2; exit 1; }
    front="$(tail -n +2 "$skill" | sed -n '1,/^---$/p')"
    printf '%s\n' "$front" | grep -qx -- '---' \
      || { echo "ai/SKILL.md's frontmatter block is never closed" >&2; exit 1; }

    printf '%s\n' "$front" | grep -q '^name: pounce$' \
      || { echo "ai/SKILL.md's frontmatter has no 'name: pounce' line" >&2; exit 1; }
    # One PHYSICAL line, by design: these guards are grep, and a description
    # written as a YAML folded scalar (`>-` plus an indented body) is valid YAML
    # that would silently stop being checked. The standard says one line.
    printf '%s\n' "$front" | grep -qE '^description: .{80,}' \
      || { echo "ai/SKILL.md's description is missing, too short to route on, or wrapped onto a second line" >&2; exit 1; }

    # A routing document that grew into a manual stops being read as one.
    lines=$(wc -l < "$skill")
    [ "$lines" -le 150 ] \
      || { echo "ai/SKILL.md is $lines lines; the standard caps a routing document at 150" >&2; exit 1; }
  ''
