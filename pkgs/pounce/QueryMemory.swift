import Foundation

// MARK: - Query memory

// What a word means to YOU.
//
// Frecency answers "what do you reach for", which is a question about the item.
// It cannot answer "what do you mean by `vs`", which is a question about the
// PAIR — and that pair is most of what people actually want from a launcher.
// Fuzzy matching has an opinion about `vs` (whatever string it fits tightest)
// and no way to be told it is wrong.
//
// So: every commit records the query that led to it, against the item that was
// taken. Pick Cursor for "vs" twice and "vs" means Cursor, however tightly
// something else fuzzy-matches those two letters. This is the one mechanism
// here that makes the palette TEACHABLE rather than merely adaptive, and it is
// the reason it can learn that "mail" means Superhuman — a pairing no amount of
// string similarity would ever propose.
//
// Three things it is built to:
//
//   1. **Prefixes are recorded too.** Typing "cursor" and committing teaches
//      "c", "cu", "cur", … as well as the whole word, because the query you
//      MEANT is the one you would have stopped at if the answer had appeared
//      sooner. Capped at `maxPrefix`: the long tail of a long query is not a
//      thing anyone types, and every recorded prefix is a row in a file that
//      gets written on the commit path.
//   2. **A weight is a share, not a count.** The boost is scaled by how much of
//      a query's history this item owns and by how much history there is at
//      all, so one accidental pick nudges and five deliberate ones decide. See
//      `boost`.
//   3. **It can RESCUE a row, not only re-rank one.** An item taught for a
//      query joins the results even when the fuzzy pass rejects it outright
//      (see `rescueBoost`) — otherwise "mail" → Superhuman could be recorded
//      forever and never once be shown.
//
// The store decays like frecency does and for the same reason, on the long
// half-life: a learned alias is a habit, and a habit is not disproved by a
// quiet fortnight. Foundation-only, so tests/run.sh compiles it.
final class QueryMemory {
    struct Pick: Codable { var weight: Double; var lastUsed: Double }

    // MARK: Constants

    // A learned alias should stick — same horizon as frecency's `long`.
    static let halfLife: Double = 30 * 86400
    static let lambda = log(2.0) / halfLife

    // Longest prefix recorded, beyond which only the whole query is. Launcher
    // queries are short; the value of prefix learning is entirely in the short
    // ones, and the bound is what keeps the table from growing with the length
    // of the longest thing anyone ever typed.
    static let maxPrefix = 8

    // Ceilings, enforced on write. `maxPicks` keeps one query from remembering
    // every row that ever won it; `maxQueries` bounds the file, which is
    // rewritten whole on the commit path.
    static let maxPicks = 4
    static let maxQueries = 3000

    // The most a query pairing can add, on the Fuzzy scale (5–20 for a real
    // match). Six is decisive for anything close and still short of an exact
    // hit on a name — a taught pairing should win a near-tie outright without
    // making the palette ignore what you typed.
    static let boostScale = 6.0

    // Above this, the item is worth showing even with no fuzzy match at all.
    // One pick is an event, two is a habit, and a row conjured out of nowhere on
    // the strength of a single accident is worse than no learning — so the bar
    // sits BETWEEN the two, with margin on each side rather than exactly on the
    // second pick. It has to: `boosts` decays before it scores, so a threshold
    // set at the undecayed value of two picks (3.0) is cleared for one instant
    // and never again, and "two picks is enough" would be false everywhere but
    // the microsecond of the second commit. At 2.5 one pick (2.0) stays below
    // for good, and two (3.0) stay above for about a fortnight — after which a
    // third renews it, which is the right shape for a habit anyway.
    static let rescueBoost = 2.5

    // query -> item key -> pick
    private var data: [String: [String: Pick]] = [:]
    private let path: URL

    init(filename: String = "query-memory.json") {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent(filename)
        if let raw = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode([String: [String: Pick]].self, from: raw) {
            data = decoded
        }
    }

    // Off the calling thread, exactly as StageSlotStore writes: `record` runs at
    // the commit, in the moment the window is being torn down, and the store is
    // the one thing here whose size grows with use.
    private let queue = DispatchQueue(label: "co.hausfold.pounce.query-memory", qos: .utility)

    private func save() {
        let snapshot = data
        queue.async { [path] in
            guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
            try? encoded.write(to: path, options: .atomic)
        }
    }

    // MARK: Pure helpers

    static func decayed(_ pick: Pick, now: Double) -> Double {
        pick.weight * exp(-lambda * max(now - pick.lastUsed, 0))
    }

    // One spelling of a query, so what is recorded and what is looked up can
    // never disagree. Internal runs of whitespace collapse: "find  files" and
    // "find files" are the same intent and splitting them halves the evidence
    // for both.
    static func normalize(_ query: String) -> String {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // Every query string a commit teaches: each prefix up to `maxPrefix`, plus
    // the whole thing when it is longer than that.
    static func keys(for query: String) -> [String] {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return [] }
        let chars = Array(normalized)
        var keys = (1...min(chars.count, maxPrefix)).map { String(chars.prefix($0)) }
        if chars.count > maxPrefix { keys.append(normalized) }
        // A prefix that ends mid-whitespace is not a query anyone types.
        return keys.filter { $0.last?.isWhitespace == false }
    }

    // Trim a query back to `maxPicks`, dropping the weakest pairings — a query
    // answered five different ways should keep the four that mean something.
    //
    // `keeping` is the row just recorded, and it is exempt. That is not a
    // nicety. A first-time pairing enters at weight 1, so on a query whose picks
    // are full and all above 1 it would be the weakest thing in the map and be
    // cut on every single commit — accumulating nothing, learnable never. Short
    // prefixes saturate first and are exactly the keys this feature is for, so
    // "vs" could be picked fifty times and still mean nothing at all. Only the
    // OTHER picks compete for the room that is left.
    static func capped(_ picks: [String: Pick], keeping key: String,
                       now: Double) -> [String: Pick] {
        guard picks.count > maxPicks else { return picks }
        let others = picks.filter { $0.key != key }
            .sorted { decayed($0.value, now: now) > decayed($1.value, now: now) }
        var kept = Dictionary(uniqueKeysWithValues: others.prefix(maxPicks - 1).map { ($0.key, $0.value) })
        kept[key] = picks[key]
        return kept
    }

    // How much this pairing is worth, given its decayed weight and the total
    // decayed weight recorded for the query.
    //
    // `share` is how much of the query's history this item owns — the whole
    // point, since a query with one clear winner should behave very differently
    // from one you have answered three ways. `confidence` is how much history
    // there is: it climbs from 1/3 at one pick towards 1, so a lone pick can
    // nudge a tie and only repetition can decide one.
    static func boost(weight: Double, total: Double) -> Double {
        guard total > 0, weight > 0 else { return 0 }
        let share = weight / total
        let confidence = total / (total + 2)
        return boostScale * share * confidence
    }

    // MARK: Instance API

    // What the current query has been answered with before, as key → boost.
    // Computed ONCE per query in DaemonState.rankedMatches and then read as a
    // dictionary lookup per item — never per item per keystroke, which is the
    // budget that pass has.
    func boosts(for query: String, now: Double = Date().timeIntervalSince1970) -> [String: Double] {
        guard let picks = data[Self.normalize(query)], !picks.isEmpty else { return [:] }
        var decayed: [String: Double] = [:]
        var total = 0.0
        for (key, pick) in picks {
            let w = Self.decayed(pick, now: now)
            guard w > 0 else { continue }
            decayed[key] = w
            total += w
        }
        return decayed.compactMapValues { w in
            let b = Self.boost(weight: w, total: total)
            return b > 0 ? b : nil
        }
    }

    // Teach: this query was answered with this item.
    func record(query: String, key: String, now: Double = Date().timeIntervalSince1970) {
        let queryKeys = Self.keys(for: query)
        guard !queryKeys.isEmpty else { return }
        for q in queryKeys {
            var picks = data[q] ?? [:]
            let existing = picks[key]
            let decayed = (existing?.weight ?? 0)
                * exp(-Self.lambda * max(now - (existing?.lastUsed ?? now), 0))
            picks[key] = Pick(weight: decayed + 1, lastUsed: now)
            data[q] = Self.capped(picks, keeping: key, now: now)
        }
        prune(now: now)
        save()
    }

    // How far below the ceiling a prune cuts. Trimming back to exactly
    // `maxQueries` would put this sort — which decays every pick on both sides
    // of every comparison — on EVERY subsequent commit that types something new,
    // for the rest of the store's life. Cutting deeper makes it rare instead.
    static let pruneTo = 2700

    // Keep the file bounded. Drops whole queries by their total decayed weight —
    // the ones nobody has typed in months go first, which is the same judgement
    // the boost makes.
    private func prune(now: Double) {
        guard data.count > Self.maxQueries else { return }
        let weight = { (picks: [String: Pick]) -> Double in
            picks.values.reduce(0.0) { $0 + Self.decayed($1, now: now) }
        }
        let ranked = data.map { (key: $0.key, picks: $0.value, weight: weight($0.value)) }
            .sorted { $0.weight > $1.weight }
        data = Dictionary(uniqueKeysWithValues: ranked.prefix(Self.pruneTo).map { ($0.key, $0.picks) })
    }
}
