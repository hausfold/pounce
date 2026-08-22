#!/bin/bash
# The shell launcher's half of the header-grammar golden table.
#
# `pounce-palette` builds its registry with an awk parser that has to agree with
# the daemon's Swift one (CommandRegistry.swift) — same fixtures, same table,
# see tests/fixtures/README.md. commandregistry_tests.swift pins the Swift side;
# this pins the awk side, against the same file, so neither can drift alone.
#
# It runs the REAL script rather than a copy of its awk, which is the only way
# the test can fail when someone edits the regex in place. Two seams make that
# possible without a built pounce:
#
#   * `pounce-palette` prepends its own directory to PATH and then calls
#     `pounce`. There is no `pounce` binary in pkgs/pounce-commands, so a stub
#     earlier in PATH wins — it captures the registry on stdin and prints
#     nothing, which the script reads as "user cancelled" and exits 0 without
#     running any fixture.
#   * every command directory it scans is env-overridable, so the fixture dir
#     can be the whole world.
set -euo pipefail
cd "$(dirname "$0")/.." # -> pkgs/pounce

palette=../pounce-commands/pounce-palette
fixtures="${POUNCE_TEST_FIXTURES:-tests/fixtures}"
table="$fixtures/header-grammar.tsv"

test -f "$table" || {
  echo "missing $table — restore the fixtures rather than deleting this check:" >&2
  echo "a header key a parser silently ignores has no other symptom." >&2
  exit 1
}

# Resolved rather than prefixed with $PWD, so POUNCE_TEST_FIXTURES works when
# it is absolute (the Swift half handles both, and a pair of tests that read one
# variable two ways is worse than either). A missing dir fails here, loudly,
# instead of producing an empty registry and a diff that blames the parser.
dir="$(cd "$fixtures/header-grammar" && pwd)" || exit 1

# Some fixtures are load-bearing WHITESPACE, and an editor's "strip trailing
# whitespace" or a bulk reformat would defuse them SILENTLY. There is no
# .editorconfig or .gitattributes standing between them and that.
#
# Guarded here are exactly the ones whose whitespace loss would NOT change the
# expected value — strip them and the table still matches while the case tests
# nothing:
#
#   trailing-space   "Trailing Space   " -> "Trailing Space", already expected
#   submenu-spaced   "true   " -> "true", still a submenu
#   tab-hash         "#<tab>pounce:" -> "# pounce:", still canonical, still parses
#   indented         "  # pounce:" -> "# pounce:", ditto
#   wide-hash        "#  pounce:" -> "# pounce:", ditto
#
# nbsp-tail is deliberately NOT here: losing its U+00A0 changes the name, so the
# table catches that one by itself. A guard for it would be noise pretending to
# be rigour.
#
# awk rather than grep: it takes `\t` in a regex on every platform, where BSD
# grep has no -P and a literal tab in a pattern is its own hazard.
intact() { # intact <file> <awk regex>
  awk -v re="$2" '$0 ~ re { hit = 1 } END { exit hit ? 0 : 1 }' "$dir/$1" && return 0
  echo "$1 has lost the whitespace it exists to test (wanted /$2/)." >&2
  echo "Stripped, this case still PASSES and tests nothing — which is why the" >&2
  echo "fixtures are checked before the table is." >&2
  return 1
}
intact trailing-space.sh '= Trailing Space   $'
intact submenu-spaced.sh '= true   $'
intact tab-hash.sh '^#\tpounce:'
intact indented.sh '^  # pounce:'
intact wide-hash.sh '^#  pounce:'

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The stub. `--launcher` and the prompt flags are ignored; stdin is the registry.
mkdir -p "$scratch/bin"
cat > "$scratch/bin/pounce" <<EOF
#!/bin/bash
cat > "$scratch/registry"
EOF
chmod +x "$scratch/bin/pounce"

# `whenFile`'s fixtures name ~/state/{yes,no}; giving the run its own HOME pins
# that the awk expands the tilde against the same place the daemon does.
mkdir -p "$scratch/home/state" "$scratch/empty-config"
printf '1\n' > "$scratch/home/state/yes"
printf '0\n' > "$scratch/home/state/no"

env -i \
  PATH="$scratch/bin:/usr/bin:/bin" \
  HOME="$scratch/home" \
  POUNCE_BUILTIN_DIR="$dir" \
  XDG_CONFIG_HOME="$scratch/empty-config" \
  /bin/bash "$palette"

test -f "$scratch/registry" || {
  echo "pounce-palette never called pounce — the stub seam this test relies on" >&2
  echo "has moved. Repoint it; do not delete the check." >&2
  exit 1
}

# The script prints a trailing newline per row; the table is stored the same way.
if ! diff -u "$table" "$scratch/registry"; then
  echo >&2
  echo "left: $table (what both parsers must produce)" >&2
  echo "right: what pounce-palette's awk header parser actually produced" >&2
  echo >&2
  echo "If you changed the grammar on purpose, change the table in the same" >&2
  echo "commit — and check CommandRegistry.swift and haus's" >&2
  echo "modules/launcher/header-grammar.nix, which are pinned to it too." >&2
  exit 1
fi

echo "ok — pounce-palette's header parser matches the golden table"
