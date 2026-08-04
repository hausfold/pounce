#!/bin/bash
# Compile + run pounce's pure-logic unit tests with the same /usr/bin/xcrun
# swiftc the app build uses (macOS + Xcode CLT required). Kept out of
# pkgs/pounce/*.swift so test code never lands in the shipped Pounce.app.
#
#   pkgs/pounce/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.." # -> pkgs/pounce

scratch="$(mktemp -d)"
bin="$scratch/pounce-tests"

# UpdateCheck.swift reads the build-stamped pounceVersion global, but
# Version.generated.swift only exists after a build.sh run (and is gitignored) —
# stub it. The suite never relies on the stub's value: isNewer takes the
# running version as a parameter.
echo 'let pounceVersion = "dev"' > "$scratch/version_stub.swift"
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
/usr/bin/xcrun swiftc -o "$bin" \
  Frecency.swift QuickAnswer.swift Calculator.swift UnitConvert.swift TimeConvert.swift \
  Currency.swift ItemSettings.swift CommandRegistry.swift UpdateCheck.swift \
  ConfigTemplate.swift Drafts.swift \
  "$scratch/version_stub.swift" \
  tests/main.swift tests/quickanswer_tests.swift tests/itemsettings_tests.swift \
  tests/commandregistry_tests.swift tests/update_tests.swift tests/symbols_tests.swift \
  tests/configtemplate_tests.swift tests/drafts_tests.swift
"$bin"
