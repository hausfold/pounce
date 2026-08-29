import Foundation

// MARK: - Next-action prediction

// What you do NEXT.
//
// A launcher session is not one decision, it is a chain: open the repo, then
// the terminal; take a screenshot, then open the notes app. Every mechanism
// here so far scores an item in isolation — how often you take it, what word
// you mean by it, where you were when you took it — and none of them can see
// that two of them keep happening in that order.
//
// So: a bigram. Each commit remembers the one before it, and if the two landed
// within `window` of each other, the PAIR is counted. Ask the store what
// usually follows what you just did and it either has a confident answer or it
// says nothing.
//
// Three rules it is built to, and each of them is about not being annoying:
//
//   1. **It offers, it does not rank.** A prediction never enters the scoring
//      pass. Nothing moves in the list because of it; it appears as one card
//      with the item's name on it. A wrong prediction therefore costs a glance
//      and nothing else — it cannot displace the row you were reaching for,
//      which is exactly the failure mode that makes "smart" launchers hostile.
//   2. **It is accepted with ⇥, never ⏎.** ⏎ belongs to the selection, always
//      and everywhere. A suggestion that competed for ⏎ would make the most
//      important key in the palette conditional on a guess.
//   3. **It has to earn the card.** `minEvidence` observations of the
//      predecessor and `minProbability` of them agreeing — a coin flip drawn on
//      the panel is furniture with a name on it, and furniture is what this
//      card exists to not be.
//
// The chain itself is persisted alongside the counts (`last`), so the very
// first ⌘Space after a commit can predict even though the palette is a fresh
// window — and, on a Mac with no daemon running, even though it is a fresh
// process. Decayed on the long half-life like every other habit here.
// Foundation-only, so tests/run.sh compiles it.
final class NextActionStore {
    struct Count: Codable { var weight: Double; var lastUsed: Double }

    // The last thing committed, and when. Persisted because the daemon is not
    // the only thing that presents the launcher (see Entry.ClientMode.runDirect).
    struct Trace: Codable { var key: String; var at: Double }

    struct Snapshot: Codable {
        var pairs: [String: [String: Count]] = [:]
        var last: Trace?
    }

    // What the store thinks is coming, and how sure it is. `evidence` is the
    // decayed number of times the predecessor has been followed by ANYTHING —
    // the n behind the p — including the continuations a cap has since rolled
    // into `otherKey`, which is what keeps that claim true.
    struct Prediction: Equatable {
        let key: String
        let probability: Double
        let evidence: Double
    }

    // MARK: Constants

    static let halfLife: Double = 30 * 86400
    static let lambda = log(2.0) / halfLife

    // How long after a commit the next one still counts as a follow-up — and,
    // deliberately the same number, how long a prediction is offered for. Five
    // minutes is about as long as "and then I did this" stays true; past it you
    // have moved on to something else and the pair would be a coincidence
    // recorded as a habit. One constant for both halves because a prediction
    // offered outside the window the statistics were gathered in would be
    // answering a question nobody collected data for.
    static let window: Double = 300

    // The bar the card has to clear. `minProbability` at 0.5 is the strong
    // reading — this continuation is likelier than every other one COMBINED —
    // and it is the strong reading on purpose: the card is drawn unasked, so it
    // should be right most of the times it appears or it becomes something the
    // eye learns to skip. `minEvidence` is the n behind that p: five follow-ups
    // is the point at which "twice in a row" stops being the whole sample.
    static let minProbability = 0.5
    static let minEvidence = 5.0

    // Where the weight of every continuation the cap threw away is kept, so the
    // `total` a probability is divided by stays the number of times you did
    // ANYTHING after this — not the number of times you did one of the six
    // things that survived. Without it the cap manufactures confidence: a
    // predecessor followed by one thing eight times and by thirty other things
    // once each has a true p of 0.2 and would report 0.6, clearing both bars and
    // drawing a card that is wrong four times in five. Not an item key — every
    // frecency key carries a prefix, so the empty string can never be one — and
    // `predict` never offers it as an answer.
    static let otherKey = ""

    // Ceilings, enforced on write. `maxNexts` counts real continuations; the
    // bucket above rides along outside it.
    static let maxNexts = 6
    static let maxKeys = 1500
    static let pruneTo = 1300

    private var pairs: [String: [String: Count]] = [:]
    private var last: Trace?
    private let path: URL

    init(filename: String = "next-action.json") {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent(filename)
        if let raw = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: raw) {
            pairs = decoded.pairs
            last = decoded.last
        }
    }

    private let queue = DispatchQueue(label: "co.hausfold.pounce.next-action", qos: .utility)

    private func save() {
        let snapshot = Snapshot(pairs: pairs, last: last)
        queue.async { [path] in
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? encoded.write(to: path, options: .atomic)
        }
    }

    // MARK: Pure helpers

    static func decayed(_ count: Count, now: Double) -> Double {
        count.weight * exp(-lambda * max(now - count.lastUsed, 0))
    }

    // Is the last commit still the thing you are in the middle of? BOTH halves
    // ask this — `record`, deciding whether the pair it is about to count is a
    // chain or a coincidence, and `prediction`, deciding whether there is
    // anything to offer — so the window can never mean one thing to the writer
    // and something else to the reader.
    //
    // `now >= trace.at` guards the clock going backwards (a timezone change, an
    // NTP correction, a restored home directory): a trace from the future is not
    // evidence of anything, and a negative age would otherwise pass the window
    // test forever.
    static func warm(_ trace: Trace?, now: Double) -> Bool {
        guard let trace else { return false }
        return now >= trace.at && now - trace.at <= window
    }

    // The strongest continuation, if it clears both bars. Pure, so the whole
    // decision is testable without a clock or a disk.
    static func predict(_ nexts: [String: Count], now: Double) -> Prediction? {
        var total = 0.0
        var best: (key: String, weight: Double)?
        for (key, count) in nexts {
            let w = decayed(count, now: now)
            guard w > 0 else { continue }
            total += w
            // The dropped-weight bucket is part of the denominator and can never
            // be the answer — see `otherKey`.
            guard key != otherKey else { continue }
            if w > (best?.weight ?? 0) { best = (key, w) }
        }
        guard let best, total >= minEvidence else { return nil }
        let p = best.weight / total
        guard p > minProbability else { return nil }
        return Prediction(key: best.key, probability: p, evidence: total)
    }

    // Trim a predecessor's continuations, keeping the one just recorded — the
    // reason is QueryMemory.capped's, verbatim: a new pairing enters at weight 1
    // and would be cut on every commit, so a workflow that changed could never
    // be learned.
    static func capped(_ nexts: [String: Count], keeping key: String,
                       now: Double) -> [String: Count] {
        let real = nexts.filter { $0.key != otherKey }
        guard real.count > maxNexts else { return nexts }
        let ranked = real.filter { $0.key != key }
            .sorted { decayed($0.value, now: now) > decayed($1.value, now: now) }
        let survivors = ranked.prefix(maxNexts - 1)
        var kept = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        kept[key] = nexts[key]
        // What was cut keeps counting, as one number decayed to `now` — the
        // denominator has to remember the tail even when the map does not.
        var carried = nexts[otherKey].map { decayed($0, now: now) } ?? 0
        for dropped in ranked.dropFirst(survivors.count) {
            carried += decayed(dropped.value, now: now)
        }
        if carried > 0 { kept[otherKey] = Count(weight: carried, lastUsed: now) }
        return kept
    }

    // MARK: Instance API

    // What usually follows the last thing committed — or nil, which is the
    // answer most of the time and is meant to be. A dictionary lookup and one
    // pass over at most `maxNexts` entries: called once per summon in
    // DaemonState.load, never on a keystroke.
    func prediction(now: Double = Date().timeIntervalSince1970) -> Prediction? {
        guard Self.warm(last, now: now), let last, let nexts = pairs[last.key] else { return nil }
        return Self.predict(nexts, now: now)
    }

    // Record a commit: count the pair it completes, then become the predecessor
    // for whatever comes next.
    //
    // A repeat of the same item is not a pair. It is the ordinary shape of
    // using a launcher twice for the same thing (a command that did not take,
    // a second window of the same app), and predicting the thing you just did
    // is the one prediction that can never be useful.
    func record(key: String, now: Double = Date().timeIntervalSince1970) {
        if Self.warm(last, now: now), let previous = last, previous.key != key {
            var nexts = pairs[previous.key] ?? [:]
            let existing = nexts[key]
            let decayed = (existing?.weight ?? 0)
                * exp(-Self.lambda * max(now - (existing?.lastUsed ?? now), 0))
            nexts[key] = Count(weight: decayed + 1, lastUsed: now)
            pairs[previous.key] = Self.capped(nexts, keeping: key, now: now)
        }
        last = Trace(key: key, at: now)
        prune(now: now)
        save()
    }

    // Keep the file bounded, dropping the predecessors with the least evidence
    // behind them — the same judgement `predict` makes. Cut well below the
    // ceiling so the sort is rare rather than per-commit (QueryMemory.pruneTo).
    private func prune(now: Double) {
        guard pairs.count > Self.maxKeys else { return }
        let weight = { (nexts: [String: Count]) -> Double in
            nexts.values.reduce(0.0) { $0 + Self.decayed($1, now: now) }
        }
        let ranked = pairs.map { (key: $0.key, nexts: $0.value, weight: weight($0.value)) }
            .sorted { $0.weight > $1.weight }
        pairs = Dictionary(uniqueKeysWithValues: ranked.prefix(Self.pruneTo).map { ($0.key, $0.nexts) })
    }
}
