import Foundation

// MARK: - Frecency

// How often you reach for something and how recently — as one number, kept on
// TWO timescales.
//
// The old model was a lifetime `count` scaled by one timestamp:
// `count · e^(−λ·(now − lastUsed))`, λ = ln2/72h. It had two faults that the
// launcher's ranking wore on its face.
//
//   1. **One timestamp decayed the whole history**, and `record()` reset it. So
//      a single click did not add one use — it un-decayed every use you had
//      ever made. A row 102 hours idle sat at 37% of its count and then leapt
//      to 100% the moment you touched it: one use, five ranks. That snap is
//      what made the empty-query list feel like it shuffled itself.
//   2. **72 hours is the wrong horizon for a habit.** It is a fine horizon for
//      "what am I doing this afternoon" and a terrible one for "what is this
//      person's Finder". Something used 53 times over months scored below
//      something used 6 times yesterday, because the only thing 72h can express
//      is the last few days.
//
// Both are the same mistake — one number trying to answer two questions — so
// there are two numbers now, and each is decayed AT WRITE TIME:
//
//     value ← value · e^(−λ·(now − lastUsed)) + 1
//
// which makes each of them a true exponential moving average where every use
// decays from its OWN moment. No snap: a click adds one use and only one.
//
//   `short` (24h half-life) — what I am doing today. A burst of use this
//   afternoon, gone by the weekend.
//   `long` (30d half-life)  — who I am. The habit underneath, which a quiet
//   week is not evidence against.
//
// Read back as `long + shortWeight · short`. The weight is 15 because the two
// converge on very different plateaus for the same usage rate (a once-a-day
// habit settles at short ≈ 2, long ≈ 44), so an unweighted sum would be `long`
// wearing a rounding error. 15 is the value at which a genuine burst — five
// uses in an hour — can outrank an established daily habit without erasing it.
//
// Ranking never uses that raw number directly; see `rankWeight`.
//
// Every consumer gets its own FILE: two live Frecency instances sharing one
// path would clobber each other's whole-file writes (the launcher and the
// window switcher both run inside the daemon).
final class Frecency {
    struct Entry: Codable {
        var short: Double
        var long: Double
        var lastUsed: Double
    }

    // MARK: Constants

    static let shortHalfLife: Double = 24 * 3600
    static let longHalfLife: Double = 30 * 86400
    static let shortLambda = log(2.0) / shortHalfLife
    static let longLambda = log(2.0) / longHalfLife

    // What one use today is worth against the habit underneath — see above.
    static let shortWeight = 15.0

    // How much a lifetime `count` is worth to `short` when migrating an old
    // store. A lifetime counter cannot tell you what someone did this
    // afternoon, so the honest seed is small: 2 is where a once-a-day habit
    // settles, and one real day of use rebuilds the true value anyway. Seeding
    // it from the count would hand every long-standing row a 15 × count bonus
    // on migration day.
    static let migrationShortSeed = 2.0

    private var data: [String: Entry] = [:]
    private let path: URL

    init(filename: String = "frecency.json") {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent(filename)
        load()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: path) else { return }
        // The current shape first; an older store falls through to the
        // migration below. Both are `[String: …]` of the same keys, so nothing
        // is lost and nothing has to be renamed.
        if let decoded = try? JSONDecoder().decode([String: Entry].self, from: raw) {
            data = decoded
            return
        }
        if let legacy = try? JSONDecoder().decode([String: LegacyEntry].self, from: raw) {
            data = legacy.mapValues { Self.migrate($0) }
        }
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: path, options: .atomic)
    }

    // MARK: Migration

    // The pre-two-timescale entry. Kept as its own type rather than as optional
    // fields on `Entry`, so the live struct stays three non-optional Doubles and
    // the migration is one pure function with one caller.
    private struct LegacyEntry: Codable { var count: Int; var lastUsed: Double }

    // Seed the two averages from a lifetime count. Deliberately CLOCK-FREE: the
    // seeds are the undecayed values as of `lastUsed`, and the ordinary read
    // path then decays them from there — so migrating is exactly "this history
    // happened, at the last moment we know about", and re-running it on a store
    // that was never written back produces the same answer every time.
    //
    // `long` takes the whole count: a 30-day half-life is close enough to the
    // span most of these counts were accumulated over that the lifetime total is
    // the best estimate of the moving average available. This is what makes
    // migration feel like remembering MORE rather than starting over — a row
    // with 53 uses and twelve idle days comes back at 40 instead of at 3.
    static func migrate(count: Int, lastUsed: Double) -> Entry {
        Entry(short: min(Double(count), migrationShortSeed),
              long: Double(count),
              lastUsed: lastUsed)
    }

    private static func migrate(_ legacy: LegacyEntry) -> Entry {
        migrate(count: legacy.count, lastUsed: legacy.lastUsed)
    }

    // MARK: Pure math

    // Split out from the instance methods so the ranking math is testable
    // without touching the filesystem or the wall clock — the same reason the
    // old `decayedScore` was.

    static func decay(_ value: Double, over age: Double, lambda: Double) -> Double {
        value * exp(-lambda * max(age, 0))
    }

    // One use, folded in at `now`. Both averages are decayed to `now` FIRST, so
    // the use being recorded is the only thing that arrives undecayed.
    static func recorded(_ entry: Entry, now: Double) -> Entry {
        let age = now - entry.lastUsed
        return Entry(short: decay(entry.short, over: age, lambda: shortLambda) + 1,
                     long: decay(entry.long, over: age, lambda: longLambda) + 1,
                     lastUsed: now)
    }

    static func combined(_ entry: Entry, now: Double) -> Double {
        let age = now - entry.lastUsed
        return decay(entry.long, over: age, lambda: longLambda)
            + shortWeight * decay(entry.short, over: age, lambda: shortLambda)
    }

    static func longScore(_ entry: Entry, now: Double) -> Double {
        decay(entry.long, over: now - entry.lastUsed, lambda: longLambda)
    }

    // Habit, on the scale a fuzzy match is scored on.
    //
    // The old shaping was `s/(s+5)`, which saturates: by a score of 20 it is
    // already at 0.8 and every heavy-use row is pinned within a whisker of 1.0.
    // On a real store — 277 keys, scores spanning 0 to 350 — the whole top
    // twenty-five landed between 0.53 and 0.99, so multiplied by its 1.5 weight
    // it separated a 353-use row from a 6-use row by 0.7 of a point against
    // Fuzzy scores that run 5 to 20. Habit was worth about four percent of the
    // decision, which is why typing anything threw your history away.
    //
    // A logarithm has no ceiling to saturate against, so it keeps discriminating
    // across the whole range that actually occurs: 0 → 0, 6 → 1.8, 44 → 3.4,
    // 400 → 5.4. That is worth roughly a word-boundary match — enough to settle
    // a near-tie in favour of the thing you actually use, and deliberately not
    // enough to put your most-used row above an exact hit on someone else's
    // name. Typing "safari" must still mean Safari.
    static let rankWeightScale = 0.9
    static func rankWeight(_ score: Double) -> Double {
        log1p(max(score, 0)) * rankWeightScale
    }

    // MARK: Instance API

    func score(for key: String) -> Double {
        guard let entry = data[key] else { return 0 }
        return Self.combined(entry, now: Date().timeIntervalSince1970)
    }

    // The habit half alone, with today's burst left out — what the Stage's
    // slots are chosen by (see StageSlots). A strip you navigate by muscle
    // memory must not reshuffle because of what you did an hour ago.
    func longScore(for key: String) -> Double {
        guard let entry = data[key] else { return 0 }
        return Self.longScore(entry, now: Date().timeIntervalSince1970)
    }

    func record(_ key: String) {
        let now = Date().timeIntervalSince1970
        data[key] = Self.recorded(data[key] ?? Entry(short: 0, long: 0, lastUsed: now), now: now)
        save()
    }
}
