import Foundation

// MARK: - Context memory

// WHERE you were when you reached for something.
//
// Frecency answers "what do you reach for" and QueryMemory answers "what does
// this word mean to you". Neither can answer "what do you reach for FROM HERE",
// and that question has an answer: the thing you press ⌘Space for over Ghostty
// at ten in the morning is reliably not the thing you press it for over Mail on
// a Sunday evening. That signal is sitting on the summon path already —
// `ItemContext.current` reads the frontmost app and the WM workspace, and the
// clock is free — and until now nothing was listening to it.
//
// Four facets, derived per summon:
//
//     app:<bundle id>   the frontmost app you pressed the key over
//     ws:<name>         the workspace/page in front (only when a `pages.mruFile`
//                       is configured — otherwise there is nothing to read)
//     hour:<bucket>     which quarter of the day, in `hourBucket`-hour blocks
//     day:wd | day:we   weekday or weekend
//
// Deliberately COARSE. An hour-of-day facet with 24 values needs 24× the
// evidence to say anything, and "half past nine" and "ten" are the same part of
// the morning to everyone but a scheduler; four-hour blocks are the resolution
// at which a person actually has a routine. Same for the week: weekday/weekend
// is the split people really live, and seven separate days would mostly hold
// one observation each.
//
// The store is `facet → item key → decayed count`, plus a `baseline` facet that
// every commit also writes, which is what makes the comparison possible at all.
// A raw count under a facet says nothing: your most-used app is the most-used
// app everywhere, so conditioning on a raw count would just re-rank by frecency
// a second time. What matters is the LIFT — how much likelier this item is here
// than it is in general:
//
//     lift = p(item | facet) / p(item) − 1
//
// Zero means "this context tells you nothing new"; positive means the context
// genuinely predicts it. An item is judged by its STRONGEST facet rather than by
// the average of them — see `multiplier`, which also explains the deliberately
// small β that keeps all of this a tilt rather than a re-shuffle.
//
// It only ever PROMOTES. A facet where an item has never been picked yields no
// signal rather than a demotion, for the same reason `QueryMemory.rescueBoost`
// sits above one pick: absence of evidence is not evidence, and burying a row
// because you have not yet happened to use it here is a failure a user cannot
// diagnose. The worst a wrong guess can do is nudge something one place up.
//
// Decays like frecency's `long` and for the same reason: where you do a thing is
// a habit, and a habit is not disproved by a quiet fortnight. Foundation-only,
// so tests/run.sh compiles it.
final class ContextMemory {
    struct Count: Codable { var weight: Double; var lastUsed: Double }

    // MARK: Constants

    static let halfLife: Double = 30 * 86400
    static let lambda = log(2.0) / halfLife

    // The facet every commit writes, against which every other facet is
    // compared. Not a real context — the name is a character no bundle id or
    // workspace can produce, so it can never collide with one.
    static let baseline = "*"

    // Hours per hour-of-day bucket. Four gives six blocks a day: the small
    // hours, early morning, morning, afternoon, evening, late. A boundary
    // straddled by a habit costs half its evidence to the neighbouring block,
    // which is the honest price of any bucketing and is why the blocks are
    // wide.
    static let hourBucket = 4

    // How hard a lift is allowed to tilt a score. It is a share of the score
    // rather than a number of points — a row the query barely matches is nudged
    // barely — so the ceiling is 16% (β × maxLift) of whatever the row already
    // scored: about 1.3 points on a short query's typical match, and more on a
    // long exact one, which is the right direction. What matters is that it is a
    // SHARE: a nudge can never overtake a row that scores more than 1/(1 + β ×
    // maxLift) — 86% — of the leader, so a genuinely better match is never
    // displaced by context, only a near-tie is settled by it. Typing "safari"
    // must still mean Safari, in every app and at every hour.
    static let beta = 0.08

    // A lift is capped before it is weighted: an item three times likelier here
    // than in general is already as strong a signal as this mechanism is willing
    // to act on, and the tail past that is where one lucky pair of clicks in a
    // rarely-used app lives.
    static let maxLift = 2.0

    // Evidence damping. A facet with `priorWeight` observations behind it is
    // believed at half strength, one with ten at ~77%. Same shape as
    // QueryMemory's `confidence`, and it exists for the same reason: the first
    // commit in a new app should not immediately reorder that app's launcher.
    static let priorWeight = 3.0

    // Where the weight of everything a cap threw away is kept. Not an item — no
    // frecency key is empty, they all carry a `cmd:` / `app:` / `mode:` prefix —
    // so it can never be mistaken for one, and `nudges` never emits an opinion
    // about it.
    //
    // It exists because a share computed over a TRUNCATED map is not a share.
    // `hour:` and `day:` facets see every commit there has ever been, keep 40 of
    // them, and would then divide by the survivors — inflating p(item | facet)
    // for exactly the rows that survived the cap, which are the rows frecency
    // already ranks first. That is the "just re-rank by frecency a second time"
    // this whole file exists to avoid. Rolling the dropped weight into one
    // bucket keeps every denominator honest at a cost of one entry per facet.
    // (QueryMemory does not do this; its cap is 4 picks on a query somebody
    // typed, where the tail really is noise. Here the tail is most of the data.)
    static let otherKey = ""

    // Ceilings, enforced on write. A facet remembers the items that mean
    // something there, not everything that ever happened there; the baseline is
    // allowed more because it is the denominator for all of them. Both count
    // real items — the `otherKey` bucket rides along outside the limit.
    static let maxKeysPerFacet = 40
    static let maxBaselineKeys = 400
    static let maxFacets = 300
    static let pruneFacetsTo = 260

    // facet -> item key -> count
    private var data: [String: [String: Count]] = [:]
    private let path: URL

    init(filename: String = "context-memory.json") {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent(filename)
        if let raw = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode([String: [String: Count]].self, from: raw) {
            data = decoded
        }
    }

    // Off the calling thread, exactly as QueryMemory and StageSlotStore write:
    // `record` runs at the commit, in the moment the window is being torn down.
    private let queue = DispatchQueue(label: "co.hausfold.pounce.context-memory", qos: .utility)

    private func save() {
        let snapshot = data
        queue.async { [path] in
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? encoded.write(to: path, options: .atomic)
        }
    }

    // MARK: Pure helpers

    static func decayed(_ count: Count, now: Double) -> Double {
        count.weight * exp(-lambda * max(now - count.lastUsed, 0))
    }

    // The facets of one summon. Pure — the clock and the calendar are passed in,
    // so a routine can be tested without waiting for Tuesday.
    //
    // `bundleId` and `workspace` are whatever `ItemContext.current` found, which
    // is legitimately nil for both: a summon over Pounce itself reports no app,
    // and a machine with no `pages.mruFile` has no workspace to report. A nil
    // facet is simply absent, and the ones that remain still condition.
    static func facets(bundleId: String?, workspace: String?,
                       at now: Double, calendar: Calendar = .current) -> [String] {
        var facets: [String] = []
        if let bundleId, !bundleId.isEmpty { facets.append("app:\(bundleId)") }
        if let workspace, !workspace.isEmpty { facets.append("ws:\(workspace)") }
        let date = Date(timeIntervalSince1970: now)
        let hour = calendar.component(.hour, from: date)
        facets.append("hour:\(hour / hourBucket)")
        facets.append(calendar.isDateInWeekend(date) ? "day:we" : "day:wd")
        return facets
    }

    // How much likelier this item is under one facet than it is in general,
    // damped by how much that facet has seen. See the header for the shape.
    //
    // Returns 0 — no opinion — whenever the comparison cannot be made: an item
    // with no history at all, a facet with no history at all, or an item this
    // facet has never seen (promotion only; see the header).
    static func lift(pair: Double, facetTotal: Double,
                     base: Double, baseTotal: Double) -> Double {
        guard pair > 0, facetTotal > 0, base > 0, baseTotal > 0 else { return 0 }
        let prior = base / baseTotal
        guard prior > 0 else { return 0 }
        let raw = (pair / facetTotal) / prior - 1
        guard raw > 0 else { return 0 }
        let confidence = facetTotal / (facetTotal + priorWeight)
        return min(raw, maxLift) * confidence
    }

    // The nudge a lift is worth, as a multiplier on the item's score.
    //
    // The lift handed in is the STRONGEST of the context's facets, not their
    // mean. Averaging looks like the fairer rule and is the wrong one twice
    // over: the facets are not independent (a workspace called T/pounce almost
    // always has the same app in front of it, so agreement between those two is
    // one observation counted twice), and the two time facets hold nearly
    // everything you have ever done, so they are silent about almost every item
    // and would dilute a real signal by a constant factor for no reason. Taking
    // the maximum says the thing that is actually true: the most specific
    // context that has an opinion is the one worth acting on, and the ceiling
    // on how far it may act is β.
    static func multiplier(lift: Double) -> Double {
        1 + beta * max(lift, 0)
    }

    // Trim a facet's picks to `limit`, dropping the weakest — `keeping` is the
    // row just recorded and is exempt, for the reason QueryMemory.capped gives
    // at length: a first-time pairing enters at weight 1 and would otherwise be
    // the thing cut on every single commit, so the newest habit could never
    // become one.
    static func capped(_ picks: [String: Count], keeping key: String,
                       limit: Int, now: Double) -> [String: Count] {
        let real = picks.filter { $0.key != otherKey }
        guard real.count > limit else { return picks }
        let ranked = real.filter { $0.key != key }
            .sorted { decayed($0.value, now: now) > decayed($1.value, now: now) }
        let survivors = ranked.prefix(max(limit - 1, 0))
        var kept = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        kept[key] = picks[key]
        // Everything cut keeps counting, as one number. Rolled up decayed to
        // `now`, which is what a bucket with no single moment of its own can
        // honestly claim.
        var carried = picks[otherKey].map { decayed($0, now: now) } ?? 0
        for dropped in ranked.dropFirst(survivors.count) {
            carried += decayed(dropped.value, now: now)
        }
        if carried > 0 { kept[otherKey] = Count(weight: carried, lastUsed: now) }
        return kept
    }

    // MARK: Instance API

    // Every item this context has an opinion about, as key → score multiplier.
    //
    // Computed ONCE per summon in DaemonState.load and then read as a dictionary
    // lookup per item inside the scoring pass — the same contract QueryMemory's
    // `boosts` has, and for the same reason: that pass already fuzzy-matches
    // every title, alias, subtitle and settings keyword on every keystroke.
    // Context does not change while a window is open, so recomputing it per
    // query would be work for an answer that cannot have changed.
    //
    // Walks the BASELINE's keys rather than the union of the facets' keys, so
    // every item is judged by the same rule and one facet's cap cannot decide
    // who is eligible for an opinion. That is a few hundred dictionary lookups,
    // once, off a map that is already in memory.
    func nudges(for facets: [String],
                now: Double = Date().timeIntervalSince1970) -> [String: Double] {
        guard let base = data[Self.baseline], !base.isEmpty, !facets.isEmpty else { return [:] }

        // Decay each facet's map once, here, rather than per item below.
        var totals: [String: Double] = [:]
        var weights: [String: [String: Double]] = [:]
        var baseTotal = 0.0
        var baseWeights: [String: Double] = [:]
        for (key, count) in base {
            let w = Self.decayed(count, now: now)
            guard w > 0 else { continue }
            // The bucket counts towards the total and never towards an answer:
            // it is the weight of everything the cap dropped, not an item.
            baseTotal += w
            if key != Self.otherKey { baseWeights[key] = w }
        }
        guard baseTotal > 0 else { return [:] }
        for facet in facets {
            guard let picks = data[facet] else { continue }
            var decayed: [String: Double] = [:]
            var total = 0.0
            for (key, count) in picks {
                let w = Self.decayed(count, now: now)
                guard w > 0 else { continue }
                decayed[key] = w
                total += w
            }
            guard total > 0 else { continue }
            weights[facet] = decayed
            totals[facet] = total
        }
        guard !weights.isEmpty else { return [:] }

        var nudges: [String: Double] = [:]
        for (key, baseWeight) in baseWeights {
            var best = 0.0
            for facet in facets {
                guard let total = totals[facet] else { continue }
                best = max(best, Self.lift(pair: weights[facet]?[key] ?? 0, facetTotal: total,
                                           base: baseWeight, baseTotal: baseTotal))
            }
            let m = Self.multiplier(lift: best)
            // Only the opinions are stored. A map holding a 1.0 for every item
            // the user has ever committed is a map the scoring pass has to
            // consult for nothing — `?? 1` at the call site is the same answer.
            if m > 1 { nudges[key] = m }
        }
        return nudges
    }

    // Teach: this item was taken from this context.
    func record(key: String, facets: [String],
                now: Double = Date().timeIntervalSince1970) {
        for facet in [Self.baseline] + facets {
            var picks = data[facet] ?? [:]
            let existing = picks[key]
            let decayed = (existing?.weight ?? 0)
                * exp(-Self.lambda * max(now - (existing?.lastUsed ?? now), 0))
            picks[key] = Count(weight: decayed + 1, lastUsed: now)
            let limit = facet == Self.baseline ? Self.maxBaselineKeys : Self.maxKeysPerFacet
            data[facet] = Self.capped(picks, keeping: key, limit: limit, now: now)
        }
        prune(now: now)
        save()
    }

    // Keep the file bounded. Apps come and go and a workspace name is whatever
    // a directory was called that week, so the facet space grows on its own;
    // the ones nobody has summoned from in months go first. The baseline is
    // never a candidate — it is the denominator every remaining facet is read
    // against, and dropping it would silently disable the whole mechanism.
    // Cut well below the ceiling for the reason QueryMemory.pruneTo gives:
    // trimming to exactly the cap would put this sort on every commit
    // thereafter.
    private func prune(now: Double) {
        guard data.count > Self.maxFacets else { return }
        let baselineEntry = data[Self.baseline]
        let weight = { (picks: [String: Count]) -> Double in
            picks.values.reduce(0.0) { $0 + Self.decayed($1, now: now) }
        }
        let ranked = data.filter { $0.key != Self.baseline }
            .map { (key: $0.key, picks: $0.value, weight: weight($0.value)) }
            .sorted { $0.weight > $1.weight }
        data = Dictionary(uniqueKeysWithValues:
            ranked.prefix(Self.pruneFacetsTo).map { ($0.key, $0.picks) })
        data[Self.baseline] = baselineEntry
    }
}
