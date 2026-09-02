#!/usr/bin/env bash
# Check every agent skill this repo ships.
#
# The guards exist because each failure they catch is INVISIBLE at runtime: a
# skill with broken frontmatter is installed, listed, and never loaded — from
# the user's side indistinguishable from the agent not knowing pounce exists.
# Nothing errors, nothing logs, the sentence just doesn't work.
#
# A script rather than a `runCommand` body (the family standard, the workshop's
# docs/agent-surface.md): CI on this repo builds Swift on a macOS runner, and a
# guard living only inside the Nix derivation runs nowhere a contributor without
# Nix will ever see it. Both call this; there is one copy of the rules.
#
#   script/check-skills.sh [ai-dir]     (default: ai/ beside this script's repo)
#
# Skills are DISCOVERED, not listed: `ai/SKILL.md` is the tool's own, and
# `ai/<name>/SKILL.md` is any sibling. A second skill that nothing checks is the
# same bug one level up.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="${1:-$root/ai}"

fail() {
  echo "check-skills: $1" >&2
  exit 1
}

found=0
for skill in "$dir/SKILL.md" "$dir"/*/SKILL.md; do
  [ -f "$skill" ] || continue
  found=$((found + 1))

  # The skill's name is the directory it installs into, so it is also what the
  # frontmatter must call itself. `ai/SKILL.md` is the tool's own.
  if [ "$skill" = "$dir/SKILL.md" ]; then
    name="pounce"
  else
    name="$(basename "$(dirname "$skill")")"
  fi

  # The frontmatter, and ONLY the frontmatter. Every client routes on `name` and
  # `description`; a header that is missing, never closed, or whose keys only
  # appear down in the body is the failure worth failing a build over.
  head -1 "$skill" | grep -qx -- '---' \
    || fail "$skill does not open with YAML frontmatter"
  front="$(tail -n +2 "$skill" | sed -n '1,/^---$/p')"
  printf '%s\n' "$front" | grep -qx -- '---' \
    || fail "$skill's frontmatter block is never closed"

  printf '%s\n' "$front" | grep -qx -- "name: $name" \
    || fail "$skill's frontmatter has no 'name: $name' line — the name must match the directory it installs into, or the skill lands under a name nothing asks for"

  # One PHYSICAL line, by design: these guards are grep, and a description
  # written as a YAML folded scalar (`>-` plus an indented body) is valid YAML
  # that would silently stop being checked. The standard says one line, and at
  # least 80 characters — a description is a routing rule, not a title.
  printf '%s\n' "$front" | grep -qE '^description: .{80,}' \
    || fail "$skill's description is missing, too short to route on, or wrapped onto a second line"

  # A routing document that grew into a manual stops being read as one.
  lines="$(wc -l < "$skill" | tr -d " ")"
  [ "$lines" -le 150 ] \
    || fail "$skill is $lines lines; the standard caps a routing document at 150"

  echo "ok — $skill ($name, $lines lines)"
done

[ "$found" -gt 0 ] || fail "no skills found under $dir — ai/SKILL.md is where the tool's own lives"
