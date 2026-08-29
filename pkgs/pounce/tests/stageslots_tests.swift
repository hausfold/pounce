import Foundation

// The Stage's promotion rule. Pure by design: the whole value of the tile strip
// is that its positions hold still, and "holds still" is a property you can
// only really assert about a function.
func runStageSlotsTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }
    func resolve(_ previous: [String], _ candidates: [(String, Double)], _ slots: Int) -> [String] {
        StageSlots.resolve(previous: previous,
                           candidates: candidates.map { (key: $0.0, score: $0.1) },
                           slots: slots)
    }

    // A first run fills from the ranking, strongest first — there is nothing to
    // be stable about yet.
    expect(resolve([], [("a", 10), ("b", 8), ("c", 6), ("d", 4)], 3) == ["a", "b", "c"],
           "an empty strip fills from the top of the ranking")

    // …and the honest answer when fewer items have earned a slot than the config
    // asked for is fewer tiles, not filler.
    expect(resolve([], [("a", 10)], 5) == ["a"],
           "a pounce with one habit gets one tile, not five")
    expect(resolve([], [], 7).isEmpty, "a pounce with no history has no strip at all")

    // THE property. The list re-ranks freely underneath; the strip does not move
    // just because today's order changed.
    expect(resolve(["a", "b", "c"], [("c", 10), ("b", 9), ("a", 8)], 3) == ["a", "b", "c"],
           "incumbents keep their SLOTS even when the ranking inverts")

    // A challenger has to clearly outgrow the weakest incumbent…
    expect(resolve(["a", "b", "c"], [("a", 10), ("b", 9), ("c", 8), ("x", 11)], 3) == ["a", "b", "c"],
           "merely outscoring an incumbent is not enough to take its slot")
    // …and when it does, it takes that incumbent's INDEX, leaving every other
    // number the hand has learned exactly where it was.
    expect(resolve(["a", "b", "c"], [("x", 20), ("a", 10), ("b", 9), ("c", 8)], 3) == ["a", "b", "x"],
           "a clear challenger replaces the weakest incumbent in place")
    // Weakest, not last: position in the strip is not rank.
    expect(resolve(["c", "a", "b"], [("x", 20), ("a", 10), ("b", 9), ("c", 8)], 3) == ["x", "a", "b"],
           "it is the weakest incumbent that goes, wherever it sits")

    // At most one slot changes per summon, however many challengers there are.
    let stormed = resolve(["a", "b", "c"], [("x", 99), ("y", 98), ("z", 97), ("a", 1), ("b", 1), ("c", 1)], 3)
    expect(stormed.filter { ["a", "b", "c"].contains($0) }.count == 2,
           "a strip never reshuffles: one tile at a time (got \(stormed))")

    // An item that no longer exists is the one thing evicted instantly — a slot
    // pointing at nothing is a hole, not stability.
    expect(resolve(["a", "gone", "c"], [("a", 10), ("c", 8), ("d", 6)], 3) == ["a", "c", "d"],
           "a vanished item frees its slot at once and the next candidate fills it")

    // Config changes, both directions.
    expect(resolve(["a", "b", "c", "d"], [("a", 10), ("b", 9), ("c", 8), ("d", 7)], 2) == ["a", "b"],
           "lowering stage.tiles truncates")
    expect(resolve(["a", "b"], [("a", 10), ("b", 9), ("c", 8), ("d", 7)], 4) == ["a", "b", "c", "d"],
           "raising stage.tiles fills the new slots without disturbing the old ones")
    expect(resolve(["a", "b"], [("a", 10)], 0).isEmpty, "no slots, no strip")

    // A hand-edited or half-written file must not be able to put one item in two
    // slots, or ⌘2 and ⌘5 would fire the same thing.
    expect(resolve(["a", "a", "b"], [("a", 10), ("b", 9), ("c", 8)], 3) == ["a", "b", "c"],
           "a duplicated slot key is collapsed, not honoured twice")

    if failures == 0 { print("ok — StageSlots tests passed") }
    return failures
}
