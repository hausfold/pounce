#!/bin/bash
# Compile + run pounce's pure-logic unit tests with the same /usr/bin/xcrun
# swiftc the app build uses (macOS + Xcode CLT required). Kept out of
# pkgs/pounce/*.swift so test code never lands in the shipped Pounce.app.
#
#   pkgs/pounce/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.." # -> pkgs/pounce

# The one shipped file that is not Swift. `pounce-palette` is copied verbatim by
# every packaging and its shebang is /bin/bash, which on macOS is 3.2.57 — a
# shell that rejects things every modern bash accepts, so a `bash -n` from $PATH
# proves nothing. The one that has actually bitten: a `case` whose patterns lack
# a leading `(`, inside a `$( )`, kills the WHOLE file at load with a syntax
# error and takes the palette with it.
if [ -x /bin/bash ]; then
  /bin/bash -n ../pounce-commands/pounce-palette
  echo "ok — pounce-palette parses under macOS /bin/bash"
fi

# …and that its awk header parser still produces the golden table the daemon's
# Swift parser is pinned to as well (tests/fixtures/README.md). It runs the real
# script over the shared fixtures, so editing that regex in place is what makes
# this fail — which is the only way three hand-mirrored parsers stay one grammar.
./tests/palette_header_test.sh

scratch="$(mktemp -d)"
bin="$scratch/pounce-tests"

# UpdateCheck.swift reads the build-stamped pounceVersion global, and Skill.swift
# the embedded pounceSkillMarkdown, but Version.generated.swift and
# Skill.generated.swift only exist after a build.sh run (both gitignored) — stub
# them. The suite never relies on the version stub's value: isNewer takes the
# running version as a parameter. The skill stub deliberately has NO trailing
# newline, because that is the shape the real generator produces — Swift's
# multiline literal excludes the newline before its closing delimiter — and
# putting it back is precisely what skill_tests.swift pins.
cat > "$scratch/generated_stubs.swift" <<'STUB'
let pounceVersion = "dev"
let pounceSkillMarkdown = "---\nname: pounce\ndescription: a stub\n---\n\n# Pounce"
STUB
# The sources under test are Foundation-only by design (no AppKit/SwiftUI) —
# for the quick-answer engines that's the QuickAnswer.swift contract — which is
# what keeps this a plain swiftc compile. Compiling them with the test files as
# one module lets tests reach module-internal API. The entry file is named
# main.swift because swiftc only permits top-level executable code (the
# assertions) in a file with that base name when several files are compiled
# together.
# (Test files carry a _tests suffix: macOS builds on a case-insensitive
# filesystem, where tests/quickanswer.swift and QuickAnswer.swift would
# collide to the same object file and silently drop one file's symbols.)
#
# The deployment target is pinned to the SAME floor build.sh uses, and for the
# same reason: 18 of the files below are shipped app sources, so an unpinned
# compile here floors them at the runner's OS and would wave through a
# newer-than-14 API that the real build then rejects — the drift this pin
# exists to close, reopened on the one job whose whole point is catching
# things early.
#
# READ out of build.sh rather than repeated here. A second literal is the same
# drift one level up: bump MACOS_MIN, forget this line, and the test job keeps
# certifying against the old floor. Sourcing build.sh would RUN it, so this
# greps the assignment instead, and refuses to guess if the shape ever changes.
macos_min="$(sed -n 's/^MACOS_MIN="\(.*\)"$/\1/p' build.sh)"
if [ -z "$macos_min" ]; then
  echo "run.sh: no MACOS_MIN= in build.sh — the deployment floor moved or was renamed." >&2
  exit 1
fi
/usr/bin/xcrun swiftc -o "$bin" \
  -target "${POUNCE_TARGET_ARCH:-$(uname -m)}-apple-macos$macos_min" \
  Frecency.swift QueryMemory.swift ContextMemory.swift NextAction.swift StageSlots.swift QuickAnswer.swift Calculator.swift UnitConvert.swift TimeConvert.swift \
  Currency.swift ItemSettings.swift FunctionKeyGesture.swift FunctionKeyRemap.swift CommandRegistry.swift UpdateCheck.swift \
  Badges.swift Json.swift Skill.swift \
  FontFamily.swift \
  ConfigTemplate.swift ConfigWriter.swift Drafts.swift AutoQuitPolicy.swift AppScanner.swift Items.swift \
  Dials.swift \
  FullscreenGate.swift \
  BugReport.swift \
  Shortcuts.swift SystemSettings.swift \
  "$scratch/generated_stubs.swift" \
  tests/main.swift tests/frecency_tests.swift tests/querymemory_tests.swift \
  tests/contextmemory_tests.swift tests/nextaction_tests.swift \
  tests/stageslots_tests.swift \
  tests/quickanswer_tests.swift tests/itemsettings_tests.swift \
  tests/badges_tests.swift \
  tests/functionkey_tests.swift tests/functionkeyremap_tests.swift \
  tests/commandregistry_tests.swift tests/update_tests.swift tests/symbols_tests.swift \
  tests/fontfamily_tests.swift \
  tests/configtemplate_tests.swift tests/configwriter_tests.swift tests/drafts_tests.swift tests/autoquit_tests.swift \
  tests/appscanner_tests.swift tests/shortcuts_tests.swift \
  tests/systemsettings_tests.swift tests/bugreport_tests.swift tests/dials_tests.swift \
  tests/fullscreengate_tests.swift \
  tests/skill_tests.swift tests/json_tests.swift
"$bin"
