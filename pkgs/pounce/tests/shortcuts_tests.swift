import Foundation

// ShortcutsStore's parser for `shortcuts list --show-identifiers`.
//
// Worth pinning because the format is Apple's and undocumented, and both failure
// directions are quiet: mis-split a name and the row is unfindable, mis-take an
// identifier and ⏎ runs the WRONG shortcut — a side effect, not a blank screen.
// The awkward case is real: shortcut names may contain parentheses ("Save to
// Photos (use with cobalt)" ships in the author's own library), so the trailing
// group is only an identifier when it actually looks like a UUID.

func runShortcutsTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // ── The ordinary shape ─────────────────────────────────────────────────

    let plain = ShortcutsStore.parse("""
    Add New Reminder (0ECC8F7A-3A52-467A-84C0-511CCE1CB9B7)
    Download File (57D35E9B-6732-4962-85BB-E0A437834EFB)
    """)
    check(plain.count == 2, "two lines parse to two entries (got \(plain.count))")
    check(plain.first?.name == "Add New Reminder", "the name is everything before the identifier")
    check(plain.first?.id == "0ECC8F7A-3A52-467A-84C0-511CCE1CB9B7", "the identifier is the UUID")

    // ── Parentheses in the NAME ────────────────────────────────────────────

    let parens = ShortcutsStore.parse(
        "Save to Photos (use with cobalt) (ADD519C9-4375-4061-9619-7E55BFB89CD9)")
    check(parens.first?.name == "Save to Photos (use with cobalt)",
          "a parenthesised name survives — the LAST group is the identifier (got \(parens.first?.name ?? "nil"))")
    check(parens.first?.id == "ADD519C9-4375-4061-9619-7E55BFB89CD9",
          "and the identifier is still the UUID")

    // ── Lines that carry no identifier are DROPPED, never guessed ──────────
    //
    // Running by name would be ambiguous the moment two shortcuts share one,
    // and the library does not prevent that. Better an absent row than a row
    // that fires something else.

    check(ShortcutsStore.parse("Add New Reminder").isEmpty,
          "a line with no identifier is dropped (list without --show-identifiers)")
    check(ShortcutsStore.parse("Weekly Report (draft)").isEmpty,
          "a trailing parenthesised group that isn't a UUID is not an identifier")
    check(ShortcutsStore.parse("(0ECC8F7A-3A52-467A-84C0-511CCE1CB9B7)").isEmpty,
          "an identifier with no name is dropped")

    // ── Blank and ragged input ─────────────────────────────────────────────

    check(ShortcutsStore.parse("").isEmpty, "empty output yields no entries")
    check(ShortcutsStore.parse("\n\n").isEmpty, "blank lines yield no entries")
    let ragged = ShortcutsStore.parse("""

      Lights Off (57D35E9B-6732-4962-85BB-E0A437834EFB)

    """)
    check(ragged.count == 1 && ragged.first?.name == "Lights Off",
          "surrounding whitespace and blank lines are trimmed away")

    // ── isUUID is a disambiguator, not a validator ─────────────────────────

    check(ShortcutsStore.isUUID("0ECC8F7A-3A52-467A-84C0-511CCE1CB9B7"), "8-4-4-4-12 hex is a UUID")
    check(ShortcutsStore.isUUID("0ecc8f7a-3a52-467a-84c0-511cce1cb9b7"), "lowercase hex too")
    check(!ShortcutsStore.isUUID("0ECC8F7A3A52467A84C0511CCE1CB9B7"), "grouping is required")
    check(!ShortcutsStore.isUUID("ZECC8F7A-3A52-467A-84C0-511CCE1CB9B7"), "non-hex is rejected")
    check(!ShortcutsStore.isUUID("use with cobalt"), "prose is rejected")
    check(!ShortcutsStore.isUUID(""), "the empty string is rejected")

    // ── The launcher row ───────────────────────────────────────────────────

    let item = PounceItem.shortcut(name: "Add to Perch Shelf",
                                   id: "0ECC8F7A-3A52-467A-84C0-511CCE1CB9B7")
    check(item.frecencyKey == "shortcut:0ECC8F7A-3A52-467A-84C0-511CCE1CB9B7",
          "the frecency key is the UUID, so a rename in Shortcuts.app keeps the history")
    check(ItemTarget.parse(item.frecencyKey) == .shortcut("0ECC8F7A-3A52-467A-84C0-511CCE1CB9B7"),
          "and that same key is a dispatchable target — one string for the row, the hotkey and `pounce run`")
    check(item.baseBoost < 0,
          "shortcuts sink below everything at an empty query and climb back by use")

    if failures == 0 { print("ok — all Shortcuts tests passed") }
    return failures
}
