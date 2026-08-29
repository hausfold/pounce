import Foundation

// ContextMemory's pure halves: how a summon becomes a set of facets, and how a
// facet's evidence becomes the small multiplicative tilt the scoring pass
// applies. The instance half (one JSON file under ~/.local/share/pounce) is
// what these were split out to avoid touching.
func runContextMemoryTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // A fixed clock, in a fixed calendar, so a routine can be tested without
    // waiting for Tuesday. 2026-08-25 is a Tuesday; 2026-08-29 a Saturday.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    func at(_ iso: String) -> Double {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso)!.timeIntervalSince1970
    }

    // MARK: facets

    let weekdayMorning = ContextMemory.facets(bundleId: "com.mitchellh.ghostty",
                                              workspace: "T/pounce",
                                              at: at("2026-08-25 10:15"), calendar: cal)
    expect(weekdayMorning.contains("app:com.mitchellh.ghostty"), "the frontmost app is a facet")
    expect(weekdayMorning.contains("ws:T/pounce"), "so is the workspace in front")
    expect(weekdayMorning.contains("hour:2"), "10:15 falls in the third four-hour block")
    expect(weekdayMorning.contains("day:wd"), "a Tuesday is a weekday")

    // The blocks are wide on purpose: half past nine and ten are the same part
    // of the morning, and an hour-of-day facet with 24 values needs 24× the
    // evidence to say anything at all.
    expect(ContextMemory.facets(bundleId: nil, workspace: nil,
                                at: at("2026-08-25 09:30"), calendar: cal).contains("hour:2"),
           "09:30 and 10:15 land in the same block")
    expect(ContextMemory.facets(bundleId: nil, workspace: nil,
                                at: at("2026-08-25 13:00"), calendar: cal).contains("hour:3"),
           "…and the afternoon is a different one")

    let weekend = ContextMemory.facets(bundleId: nil, workspace: nil,
                                       at: at("2026-08-29 10:15"), calendar: cal)
    expect(weekend.contains("day:we"), "a Saturday is a weekend")
    expect(weekend.count == 2, "a summon over Pounce itself with no mruFile still has a clock")
    expect(!weekend.contains(where: { $0.hasPrefix("app:") || $0.hasPrefix("ws:") }),
           "…and reports neither an app nor a workspace rather than an empty one")

    expect(ContextMemory.facets(bundleId: "", workspace: "",
                                at: at("2026-08-25 10:15"), calendar: cal).count == 2,
           "empty strings are absent facets, not facets named nothing")

    // MARK: lift

    // The whole point: a raw count says nothing, because your most-used item is
    // the most-used item everywhere. 40% of this app's commits against 10% of
    // all of them is a lift; 10% against 10% is not.
    let specific = ContextMemory.lift(pair: 40, facetTotal: 100, base: 10, baseTotal: 100)
    let indifferent = ContextMemory.lift(pair: 10, facetTotal: 100, base: 10, baseTotal: 100)
    expect(specific > 0, "an item likelier here than in general is lifted")
    expect(indifferent == 0, "an item exactly as likely here as anywhere tells you nothing")

    // Promotion only — see the header. Absence of evidence is not evidence.
    expect(ContextMemory.lift(pair: 0, facetTotal: 100, base: 10, baseTotal: 100) == 0,
           "an item this facet has never seen is left alone, never demoted")
    expect(ContextMemory.lift(pair: 1, facetTotal: 100, base: 50, baseTotal: 100) == 0,
           "…and neither is one that is rarer here than in general")

    // Nothing to compare against.
    expect(ContextMemory.lift(pair: 5, facetTotal: 10, base: 0, baseTotal: 100) == 0,
           "an item with no history at all gets no opinion")
    expect(ContextMemory.lift(pair: 0, facetTotal: 0, base: 10, baseTotal: 100) == 0,
           "a facet with no history at all gets no opinion")

    // Damping: the same ratio, believed less when there is less behind it. This
    // is what stops the first commit in a new app reordering that app's launcher.
    let thin = ContextMemory.lift(pair: 2, facetTotal: 5, base: 10, baseTotal: 100)
    let thick = ContextMemory.lift(pair: 40, facetTotal: 100, base: 10, baseTotal: 100)
    expect(thin < thick, "the same lift is worth less on five observations than on a hundred")
    expect(thin > 0, "…but it is still worth something")

    // Capped before it is weighted, so one lucky pair of clicks in a
    // rarely-used app cannot buy an unbounded promotion.
    let extreme = ContextMemory.lift(pair: 990, facetTotal: 1000, base: 1, baseTotal: 1000)
    expect(extreme <= ContextMemory.maxLift, "a lift is capped (got \(extreme))")

    // MARK: multiplier

    expect(ContextMemory.multiplier(lift: 0) == 1, "no lift is no change at all")
    let ceiling = ContextMemory.multiplier(lift: ContextMemory.maxLift)
    expect(ceiling == 1 + ContextMemory.beta * ContextMemory.maxLift,
           "the strongest possible context is worth exactly β × maxLift")
    // The calibration that matters: on a Fuzzy score of 20 — an exact hit on a
    // name — the biggest tilt this can apply must stay under what a
    // word-boundary match is worth, or typing a name would stop meaning it.
    expect(20 * (ceiling - 1) < 4, "even a maximal nudge cannot outrun the query itself")
    expect(ContextMemory.multiplier(lift: -5) == 1, "a negative lift can never demote")

    // MARK: capped

    let now = at("2026-08-25 10:15")
    var picks: [String: ContextMemory.Count] = [:]
    for i in 0..<6 { picks["app:/old\(i)"] = .init(weight: Double(10 + i), lastUsed: now) }
    picks["cmd:new"] = .init(weight: 1, lastUsed: now)
    let kept = ContextMemory.capped(picks, keeping: "cmd:new", limit: 4, now: now)
    expect(kept.count == 4, "a facet is trimmed to its limit")
    expect(kept["cmd:new"] != nil,
           "the row just recorded survives — it enters at weight 1 and would " +
           "otherwise be cut on every commit, so a new habit could never form")
    expect(kept["app:/old0"] == nil && kept["app:/old5"] != nil,
           "…and what it costs is the weakest of the others")

    if failures == 0 { print("ok — ContextMemory tests passed") }
    return failures
}
