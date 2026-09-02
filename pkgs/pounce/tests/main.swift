// Unit tests for pounce's pure logic: the ranking math (tests/frecency_tests.swift,
// querymemory_tests.swift, contextmemory_tests.swift, nextaction_tests.swift,
// stageslots_tests.swift) and the quick-answer
// engines (tests/quickanswer_tests.swift). Deliberately assertion-based
// (no XCTest/SwiftPM) so it compiles with the very same `xcrun swiftc` the app
// build uses — see tests/run.sh. Lives under tests/ so pkgs/pounce/*.swift (the
// app's single-module glob) never sweeps it into the shipped binary. Named
// main.swift because the assertions run as top-level code, which swiftc only
// allows in a file with that base name when compiled alongside the sources
// under test.
//
// Everything under test here is a pure function or a pure static. The stores
// they belong to (Frecency, QueryMemory, ContextMemory, NextActionStore,
// StageSlotStore) touch the filesystem
// and the wall clock in their instance halves, which is exactly what the pure
// halves were split out to avoid.

import Foundation

var failures = 0

failures += runFrecencyTests()
failures += runQueryMemoryTests()
failures += runContextMemoryTests()
failures += runNextActionTests()
failures += runStageSlotsTests()
failures += runQuickAnswerTests()
failures += runItemSettingsTests()
failures += runBadgesTests()
failures += runFunctionKeyTests()
failures += runFunctionKeyRemapTests()
failures += runCommandRegistryTests()
failures += runUpdateNudgeTests()
failures += runBugReportTests()
failures += runSymbolsTests()
failures += runFontFamilyTests()
failures += runConfigTemplateTests()
failures += runConfigWriterTests()
failures += runDraftsTests()
failures += runAutoQuitTests()
failures += runAppScannerTests()
failures += runShortcutsTests()
failures += runSystemSettingsTests()
failures += runDialsTests()
failures += runFullscreenGateTests()
failures += runSkillTests()
failures += runJsonTests()

if failures == 0 {
    exit(0)
} else {
    FileHandle.standardError.write(Data("\(failures) test(s) failed\n".utf8))
    exit(1)
}
