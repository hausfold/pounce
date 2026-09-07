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
    // Keys only, for the assertions that are about ORDER rather than credit.
    // Everything is idle 0 unless a test says otherwise, so the staleness rule
    // stays out of the way of the cases that are not about it.
    func resolve(_ previous: [String], _ candidates: [(String, Double)], _ slots: Int) -> [String] {
        full(previous.map { StageSlots.Slot(key: $0) }, candidates, slots).map { $0.key }
    }
    func full(_ previous: [StageSlots.Slot], _ candidates: [(String, Double)],
              _ slots: Int) -> [StageSlots.Slot] {
        StageSlots.resolve(previous: previous,
                           candidates: candidates.map { (key: $0.0, score: $0.1, idle: 0) },
                           slots: slots)
    }
    // …and the same with an idle time per candidate, in days.
    func aged(_ previous: [String], _ candidates: [(String, Double, Double)],
              _ slots: Int) -> [String] {
        StageSlots.resolve(previous: previous.map { StageSlots.Slot(key: $0) },
                           candidates: candidates.map {
                               (key: $0.0, score: $0.1, idle: $0.2 * 86400)
                           },
                           slots: slots).map { $0.key }
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

    // MARK: absence is not the same question as gone

    // THE regression that matters most here. Several item sources legitimately
    // return nothing on a given summon — the Shortcuts library and the System
    // Settings panes both give up past a 0.25s cold budget, and `items` scoping
    // hides workspace-pinned rows elsewhere. Evicting on the first absence
    // backfilled the slot from the live ranking and PERSISTED it, so one cold
    // login permanently rearranged a strip whose whole value is not rearranging.
    let cold = full([StageSlots.Slot(key: "a"), StageSlots.Slot(key: "shortcut:x"),
                     StageSlots.Slot(key: "c")],
                    [("a", 10), ("c", 8), ("d", 6)], 3)
    expect(cold.map { $0.key } == ["a", "shortcut:x", "c"],
           "a source that did not load keeps its slot, and nothing backfills over it")
    expect(cold.first { $0.key == "shortcut:x" }?.misses == 1, "…on credit, counted")

    // …and it finds its position again the moment the source warms up.
    let warm = full(cold, [("a", 10), ("shortcut:x", 9), ("c", 8), ("d", 6)], 3)
    expect(warm.map { $0.key } == ["a", "shortcut:x", "c"], "a warmed source returns to its slot")
    expect(warm.first { $0.key == "shortcut:x" }?.misses == 0, "…with a clean sheet")

    // A genuinely gone item still frees its slot — just not on the first miss.
    var fading = [StageSlots.Slot(key: "a"), StageSlots.Slot(key: "gone"), StageSlots.Slot(key: "c")]
    for _ in 1..<StageSlots.evictAfterMisses {
        fading = full(fading, [("a", 10), ("c", 8), ("d", 6)], 3)
        expect(fading.map { $0.key }.contains("gone"), "an absence short of the limit is not an eviction")
    }
    fading = full(fading, [("a", 10), ("c", 8), ("d", 6)], 3)
    expect(fading.map { $0.key } == ["a", "c", "d"],
           "…but a sustained one is, and the next candidate fills the slot")

    // A slot waiting out a miss cannot be taken by a challenger either: it has
    // no score to be compared against, and treating a missing score as 0 would
    // be eviction-on-absence wearing a different hat.
    let besieged = full([StageSlots.Slot(key: "a"), StageSlots.Slot(key: "away"), StageSlots.Slot(key: "c")],
                        [("x", 999), ("a", 10), ("c", 8)], 3)
    expect(besieged.map { $0.key }.contains("away"),
           "a challenger cannot take the slot of an item that merely did not load")

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

    // MARK: holds still, but does not stay wrong

    // The regression this half exists for. An incumbent never re-enters the
    // ordering, so before this a pair's relative positions were fixed at seed
    // time however far the scores later diverged — the most-used item on a real
    // Mac sat at ⌘7 behind something scoring 8× less, for weeks.
    expect(resolve(["a", "b", "c"], [("c", 100), ("a", 10), ("b", 9)], 3) == ["a", "c", "b"],
           "a decisive inversion swaps that one pair")

    // One pair per summon, adjacent, bottom-up: a buried tile climbs at a pace
    // the hand can follow rather than teleporting to the front.
    expect(resolve(["a", "c", "b"], [("c", 100), ("a", 10), ("b", 9)], 3) == ["c", "a", "b"],
           "…and keeps climbing one slot at a time")
    // …and then stops. This is what makes it a correction and not a stirring.
    expect(resolve(["c", "a", "b"], [("c", 100), ("a", 10), ("b", 9)], 3) == ["c", "a", "b"],
           "…until nothing is decisively out of place, and then never again")

    // Anything short of the margin is a near-tie, and near-ties are exactly what
    // a strip must not shuffle. (`reorderMargin` is 2.0; 19 vs 10 is not enough.)
    expect(resolve(["a", "b"], [("b", 19), ("a", 10)], 2) == ["a", "b"],
           "outscoring the tile above you is not enough to swap with it")

    // Membership outranks position: a summon that already changed WHAT is on the
    // strip does not also change where things sit.
    expect(resolve(["a", "b", "c"], [("x", 1000), ("c", 100), ("a", 10), ("b", 9)], 3) == ["a", "x", "c"],
           "a promotion and a swap never land in the same summon")
    expect(resolve(["a", "x", "c"], [("x", 1000), ("c", 100), ("a", 10)], 3) == ["x", "a", "c"],
           "…the inversion waits for the next one")

    // A slot waiting out a miss has no score, and a missing score is not a low
    // score — the correction sits the summon out rather than guessing.
    expect(resolve(["a", "away", "c"], [("c", 100), ("a", 10)], 3) == ["a", "away", "c"],
           "a cold source freezes the correction, not just the promotion")

    // MARK: the margin defends a habit, not a squatter

    // `promoteMargin` is there to stop two comparable items trading a slot on
    // noise. An incumbent the user put down ten days ago is not comparable to
    // one they used today, and a 30-day half-life is far too slow to say so.
    expect(aged(["a", "b", "c"], [("a", 100, 0), ("b", 50, 0), ("x", 12, 0), ("c", 10, 10)], 3)
            == ["a", "b", "x"],
           "a stale incumbent loses the margin to a fresher challenger")

    // Asymmetric on purpose: it takes a FRESHER challenger to collect that. A
    // long-idle challenger still has to clear the full 1.5× against a tile that
    // is still in use, or every fortnight-old row would rattle the strip.
    expect(aged(["a", "b", "c"], [("a", 100, 0), ("b", 50, 0), ("x", 12, 10), ("c", 10, 0)], 3)
            == ["a", "b", "c"],
           "a stale challenger still pays the full margin")

    // `Frecency.idle` answers `.infinity` for a key it has never seen. The live
    // caller filters those out (score > 0), but `resolve` is pure and callable
    // on its own, and `∞ − ∞` is NaN — which fails every comparison and so would
    // mean the exact OPPOSITE of the sentinel's intent. Both directions:
    let never = Double.infinity
    expect(StageSlots.resolve(previous: [StageSlots.Slot(key: "c")],
                              candidates: [(key: "x", score: 12, idle: never),
                                           (key: "c", score: 10, idle: never)],
                              slots: 1).map { $0.key } == ["c"],
           "two items with no history at all are not 'stale' relative to each other")
    expect(StageSlots.resolve(previous: [StageSlots.Slot(key: "c")],
                              candidates: [(key: "x", score: 12, idle: 0),
                                           (key: "c", score: 10, idle: never)],
                              slots: 1).map { $0.key } == ["x"],
           "…but a never-used incumbent is stale against one used today")

    if failures == 0 { print("ok — StageSlots tests passed") }
    return failures
}
