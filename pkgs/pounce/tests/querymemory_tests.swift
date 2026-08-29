import Foundation

// QueryMemory's pure halves: how a typed query becomes the set of strings a
// commit teaches, and how a remembered pairing turns into a score on the same
// scale a Fuzzy match lives on.
func runQueryMemoryTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // MARK: normalize

    expect(QueryMemory.normalize("  Find   Files ") == "find files",
           "case and runs of whitespace collapse, so one intent is one key")
    expect(QueryMemory.normalize("   ") == "", "whitespace alone is not a query")

    // MARK: keys

    let keys = QueryMemory.keys(for: "cursor")
    expect(keys == ["c", "cu", "cur", "curs", "curso", "cursor"],
           "every prefix is taught — the query you MEANT is the one you'd have stopped at")

    // Bounded, or the table grows with the longest thing anyone ever typed.
    let long = QueryMemory.keys(for: "system settings display")
    expect(long.count <= QueryMemory.maxPrefix + 1,
           "past the prefix cap only the whole query is kept (got \(long.count))")
    expect(long.last == "system settings display", "…and the whole query IS kept")
    // "system s" is the 8-character prefix and it ends mid-word-gap — nobody
    // types that and stops, so it is dropped rather than recorded as an intent.
    expect(long.allSatisfy { $0.last?.isWhitespace == false },
           "a prefix ending mid-space is not a query anyone types")
    expect(!long.contains("system "), "…specifically, the trailing-space prefix is dropped")
    expect(long.contains("system") && long.contains("s"),
           "the prefixes on either side of it are still taught")

    expect(QueryMemory.keys(for: "  ").isEmpty, "an empty query teaches nothing")

    // MARK: boost

    // One pick nudges; repetition decides. The gap between these two numbers is
    // the entire safety margin against a single mis-click becoming a rule.
    let onePick = QueryMemory.boost(weight: 1, total: 1)
    let fivePicks = QueryMemory.boost(weight: 5, total: 5)
    expect(onePick < QueryMemory.rescueBoost,
           "one pick is an event, and cannot conjure a row the search rejected (got \(onePick))")
    expect(QueryMemory.boost(weight: 2, total: 2) >= QueryMemory.rescueBoost,
           "two picks for the same query is a habit, and can")
    expect(fivePicks > onePick, "more evidence is worth more")
    expect(fivePicks <= QueryMemory.boostScale, "the boost is capped at its scale")

    // A query answered several ways splits its evidence — which is the point of
    // scoring a SHARE rather than a count. "s" meaning Safari half the time
    // must not outrank "s" meaning Safari every time.
    let split = QueryMemory.boost(weight: 3, total: 6)
    let clear = QueryMemory.boost(weight: 6, total: 6)
    expect(split < clear, "an ambiguous query nudges less than a decided one")

    expect(QueryMemory.boost(weight: 0, total: 0) == 0, "no history is no boost")
    expect(QueryMemory.boost(weight: 1, total: 0) == 0, "a zero total cannot divide")

    // …and the ceiling that keeps a taught pairing from ignoring what was typed.
    expect(QueryMemory.boostScale < 12,
           "a taught pairing must stay short of an exact match on a name")

    if failures == 0 { print("ok — QueryMemory tests passed") }
    return failures
}
