import Foundation

// Frecency's ranking math: the two-timescale averages, decay-on-write, the
// migration off the old lifetime counter, and the log shaping the launcher
// scores habit with. All of it is pure statics for exactly this reason — the
// instance API touches the filesystem and the wall clock.
func runFrecencyTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }
    func expectClose(_ a: Double, _ b: Double, _ message: String, eps: Double = 1e-6) {
        if abs(a - b) > eps {
            FileHandle.standardError.write(Data("FAIL: \(message) (got \(a), want \(b))\n".utf8))
            failures += 1
        }
    }

    let day = 24.0 * 3600

    // MARK: decay

    expectClose(Frecency.decay(8, over: 0, lambda: Frecency.shortLambda), 8,
                "age 0 decays nothing")
    expectClose(Frecency.decay(8, over: day, lambda: Frecency.shortLambda), 4,
                "one short half-life (24h) halves")
    expectClose(Frecency.decay(8, over: 30 * day, lambda: Frecency.longLambda), 4,
                "one long half-life (30d) halves")
    // Clock skew (a restored backup, an NTP correction) must not amplify.
    expectClose(Frecency.decay(8, over: -day, lambda: Frecency.shortLambda), 8,
                "a negative age is clamped, never a multiplier")

    // MARK: decay-on-write is what removes the old model's snap

    // THE regression this whole file exists for. Under the old model a use was
    // recorded by resetting one timestamp, which un-decayed the entire lifetime
    // count: a row idle for days leapt back to its full historical weight on a
    // single click. Here a use adds one use.
    let stale = Frecency.Entry(short: 40, long: 40, lastUsed: 0)
    let touched = Frecency.recorded(stale, now: 30 * day)
    expectClose(touched.long, 20 + 1, "a use adds one to the decayed long average, not a reset")
    expect(touched.short < 1.001, "a month-old short average is spent, and one use rebuilds it from ~0")
    expect(touched.lastUsed == 30 * day, "recording stamps the moment")

    // …and repeated use accumulates rather than saturating at 1.
    var burst = Frecency.Entry(short: 0, long: 0, lastUsed: 0)
    for i in 1...5 { burst = Frecency.recorded(burst, now: Double(i) * 60) }
    expect(burst.short > 4.9 && burst.short <= 5,
           "five uses in five minutes is worth ~5, not 1 (got \(burst.short))")

    // MARK: the two timescales answer different questions

    // A daily habit settles where the constants say it does. These two plateaus
    // are what `shortWeight` is calibrated against — if either moves, the weight
    // has to be re-derived, so they are pinned here.
    var daily = Frecency.Entry(short: 0, long: 0, lastUsed: 0)
    for i in 1...400 { daily = Frecency.recorded(daily, now: Double(i) * day) }
    expect(daily.short > 1.9 && daily.short < 2.1,
           "a once-a-day habit plateaus at short ≈ 2 (got \(daily.short))")
    expect(daily.long > 42 && daily.long < 45,
           "a once-a-day habit plateaus at long ≈ 44 (got \(daily.long))")

    // The burst-beats-habit calibration: five uses in the last hour outranks
    // that established daily habit, which is the whole reason shortWeight is 15.
    var today = Frecency.Entry(short: 0, long: 0, lastUsed: 400 * day)
    for i in 1...5 { today = Frecency.recorded(today, now: 400 * day + Double(i) * 600) }
    let now = 400 * day + 3600
    expect(Frecency.combined(today, now: now) > Frecency.combined(daily, now: now),
           "five uses in the last hour outranks a daily habit")

    // …but a single use does not erase months of history.
    var once = Frecency.Entry(short: 0, long: 0, lastUsed: 0)
    once = Frecency.recorded(once, now: 400 * day)
    expect(Frecency.combined(once, now: 400 * day) < Frecency.combined(daily, now: 400 * day),
           "one use does not outrank a year of daily use")

    // A quiet fortnight is not evidence against a habit — the specific failure
    // of the old 72h-only model, which had nothing left to say after a week.
    let quiet = Frecency.combined(daily, now: 400 * day + 14 * day)
    expect(quiet > 0.5 * Frecency.combined(daily, now: 400 * day + 60 * day),
           "two weeks idle keeps most of a habit; two months does not")
    expect(quiet > 20, "a daily habit survives a fortnight away (got \(quiet))")

    // MARK: migration

    // Clock-free by construction: the seeds are the values as of `lastUsed`, so
    // migrating twice gives the same answer as migrating once.
    let seeded = Frecency.migrate(count: 53, lastUsed: 1000)
    expectClose(seeded.long, 53, "long takes the whole lifetime count")
    expectClose(seeded.short, Frecency.migrationShortSeed,
                "short is seeded conservatively — a lifetime counter says nothing about today")
    expectClose(seeded.lastUsed, 1000, "migration keeps the last-used stamp")
    expectClose(Frecency.migrate(count: 1, lastUsed: 1000).short, 1,
                "a one-use entry seeds short from the count, not from the cap")

    // The behaviour the migration exists for: a row with real history and a
    // fortnight of silence comes back as history, not as noise. Under the old
    // 72h model this exact entry scored 3.05 and sat below a six-use row.
    let remembered = Frecency.longScore(Frecency.migrate(count: 53, lastUsed: 0), now: 12 * day)
    expect(remembered > 35, "53 uses and 12 idle days is still a habit (got \(remembered))")

    // MARK: rankWeight

    // The property the old `s/(s+5)` shaping lost: it must keep separating
    // scores across the whole range that actually occurs. On a real store that
    // range is 0–350, where the old curve pinned everything above 20 into the
    // top fifth of its output.
    expectClose(Frecency.rankWeight(0), 0, "never used is worth nothing")
    expect(Frecency.rankWeight(-5) == 0, "a negative score cannot become a bonus")
    let w6 = Frecency.rankWeight(6), w44 = Frecency.rankWeight(44), w400 = Frecency.rankWeight(400)
    expect(w6 < w44 && w44 < w400, "more use always ranks higher")
    expect(w400 - w6 > 2.5,
           "a heavy habit and a light one differ by more than a rounding error (got \(w400 - w6))")
    // …and it stays SMALL enough that typing a name still wins. A perfect
    // prefix match on a short title scores ~12 in Fuzzy; habit may not cover
    // that gap on its own, or "safari" would stop meaning Safari.
    expect(w400 < 6, "habit tops out below an exact name match (got \(w400))")

    if failures == 0 { print("ok — Frecency ranking tests passed") }
    return failures
}
