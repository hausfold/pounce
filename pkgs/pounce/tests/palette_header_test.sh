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
  POUNCE_BUILTIN_DIR="$PWD/$fixtures/header-grammar" \
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
