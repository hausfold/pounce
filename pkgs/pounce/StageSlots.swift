import Foundation

// MARK: - The Stage's slots

// Which items the tile strip holds, and — just as much the point — WHERE each
// one sits.
//
// The strip used to be `visible.prefix(7)`: the same ranking as the list,
// re-derived on every summon. That made it two things at once and neither
// well. It duplicated the list's own head, and because it moved with the list
// it could not be navigated blind — the tile in position three was whatever
// scored third this second.
//
// A strip and a list are answers to different questions, so they are ranked by
// different numbers now:
//
//   The LIST is live. It ranks on the full frecency score (`long + 15·short`),
//   so this afternoon's burst floats to the top where you can see it, and it
//   re-orders freely because reading it is how you use it.
//
//   The STRIP is muscle memory. It ranks on the HABIT alone (`long`, 30-day
//   half-life — today's burst deliberately excluded) and then holds its
//   positions across summons, so ⌘3 is the same thing this week that it was
//   last week. A tile you can hit without looking is worth more than a tile
//   that is optimally ranked; churn destroys the entire value of the zone.
//
// Stability is not a side effect of the long half-life — it is enforced, here.
// An incumbent keeps its slot until a challenger beats it by `promoteMargin`,
// and then exactly ONE slot changes per summon: the challenger takes the
// weakest incumbent's INDEX rather than displacing everything below it. So the
// strip drifts a tile at a time as your habits actually change, and never
// reshuffles.
//
// Held positions are not frozen FOREVER, though, and the first version of this
// file made that mistake. An incumbent never re-enters the ordering, so once
// two tiles were placed their relative positions could not change however far
// their scores diverged: a real store had the single most-used item on the Mac
// sitting at ⌘7 with something scoring 8× less at ⌘1, because that is where the
// two happened to land at seed time weeks earlier. "Positions hold still" has
// to mean stable, not wrong forever — so a DECISIVE inversion (an item beating
// the one above it by `reorderMargin`) swaps that one pair, at most one swap per
// summon, and never in the same summon as a promotion. Each step is a single
// adjacent move the hand can absorb, it converges and then goes quiet, and it
// cannot oscillate: after a swap the pair is ordered by more than the margin, so
// the reverse test can never fire.
//
// The other thing the margin got wrong is that it defended an incumbent it had
// no business defending. `promoteMargin` exists to stop two COMPARABLE items
// trading a slot on noise; when the incumbent has been idle `staleLead` longer
// than the challenger, the challenger is not noise, it is a habit that moved,
// and the margin drops to 1.0 so the score alone decides. Note this is asymmetric
// on purpose — it takes a FRESHER challenger to collect it, so a long-idle
// challenger still has to clear the full 1.5× against a tile you used today.
//
// An item that no longer exists does have to free its slot — a slot pointing at
// nothing is a hole, not stability — but "not in this summon's item list" is NOT
// the same question as "gone", and treating them as one destroys the feature.
// Several launcher sources legitimately return nothing on a given summon: the
// Shortcuts library and the System Settings panes both give up past a 0.25s cold
// budget (the first ⌘Space after login), a command directory can be unreadable
// mid-rebuild, and `items` scoping hides workspace-pinned rows the moment you
// summon somewhere else. Evicting on the first absence would backfill the slot
// from the live ranking and PERSIST that — so one cold login would permanently
// rearrange a strip whose whole value is not rearranging. Absence is counted
// instead, and only `evictAfterMisses` consecutive ones mean gone. A slot
// waiting out a miss keeps its position and simply is not drawn that summon.
//
// Foundation-only (`resolve` is pure), so tests/run.sh compiles it.
enum StageSlots {
    // How much better a challenger must be than the weakest incumbent to take
    // its slot. 1.5 is roughly "half again the habit" — reached in a week or
    // two of genuinely using something new, and never by noise. Not always
    // collected: an incumbent that has been idle `staleLead` longer than its
    // challenger falls back to a bare 1.0 — see the header.
    static let promoteMargin = 1.5

    // Consecutive summons an incumbent may be missing from the item list before
    // it counts as gone rather than as not-loaded-yet. Three is enough to ride
    // out a cold source (which warms within one summon) while still freeing an
    // uninstalled app's slot within seconds of actual use.
    static let evictAfterMisses = 3

    // How much better a tile must be than the tile ABOVE it before the two
    // swap. Deliberately larger than `promoteMargin`: changing which things are
    // on the strip is a smaller event than changing where they are, because
    // membership is read and position is muscle memory. At 2.0 the near-ties
    // that a live ranking would shuffle every summon never move at all, and only
    // an inversion nobody would defend does.
    static let reorderMargin = 2.0

    // How much staler than its challenger an incumbent must be before it stops
    // collecting `promoteMargin`. Three days is past a weekend — a Friday habit
    // is not stale on Monday — and well inside the 30-day half-life the scores
    // themselves decay on, which is far too slow to express "I stopped using
    // this".
    static let staleLead: Double = 3 * 86400

    // One slot: what holds it, and how many summons running it has failed to
    // turn up. `misses` is emphatically not a measure of disuse — that is what
    // the habit score is for.
    struct Slot: Codable, Equatable {
        var key: String
        var misses: Int = 0
    }

    // The new slot order, given the previous one and today's candidates.
    //
    // `candidates` must be sorted by score, strongest first, and must contain
    // only items eligible to BE a tile — see DaemonState.load, which requires a
    // positive habit score and no minimum query length. `idle` is seconds since
    // that item was last committed; it is carried alongside the score rather
    // than derived from it because a 30-day half-life cannot tell a modest daily
    // habit from a burst a fortnight ago, and the two deserve different answers.
    //
    // Pure — the clock is the caller's, in `idle` — so the whole promotion rule
    // is testable without a clock or a disk.
    static func resolve(previous: [Slot],
                        candidates: [(key: String, score: Double, idle: Double)],
                        slots: Int) -> [Slot] {
        guard slots > 0 else { return [] }
        var scores: [String: Double] = [:]
        var idles: [String: Double] = [:]
        for c in candidates where scores[c.key] == nil {
            scores[c.key] = c.score
            idles[c.key] = c.idle
        }

        // Incumbents, in their existing order. One that turned up keeps its slot
        // with a clean sheet; one that did not keeps it on credit until the
        // credit runs out. Deduped: a hand-edited or half-written file must not
        // be able to put one item in two slots, or two chords would fire one row.
        var seen = Set<String>()
        var order: [Slot] = []
        for slot in previous {
            guard !seen.contains(slot.key) else { continue }
            if scores[slot.key] != nil {
                seen.insert(slot.key)
                order.append(Slot(key: slot.key, misses: 0))
            } else if slot.misses + 1 < evictAfterMisses {
                seen.insert(slot.key)
                order.append(Slot(key: slot.key, misses: slot.misses + 1))
            }
        }
        if order.count > slots { order = Array(order.prefix(slots)) }

        // Empty slots — a first run, a raised `stage.tiles`, an eviction — fill
        // from the strongest candidates not already placed. This is the only
        // path that adds more than one tile at a time, and it has to be: there
        // is nothing to be stable about yet.
        for c in candidates where order.count < slots {
            guard !seen.contains(c.key) else { continue }
            seen.insert(c.key)
            order.append(Slot(key: c.key))
        }

        // Whether the fill or an eviction already changed WHAT is on the strip.
        // Computed before the promotion, which is the other way membership moves.
        let membershipChanged = Set(previous.map { $0.key }) != Set(order.map { $0.key })

        // …and the promotion, at most one per summon. Only an incumbent that
        // actually turned up can be displaced: one waiting out a miss has no
        // score to be compared against, and letting a challenger take its slot
        // on that basis is exactly the eviction-on-absence this guards.
        var promoted = false
        let present = order.filter { scores[$0.key] != nil }
        if order.count == slots,
           let weakest = present.min(by: { (scores[$0.key] ?? 0) < (scores[$1.key] ?? 0) }),
           let challenger = candidates.first(where: { !seen.contains($0.key) }) {
            // The margin defends a tile that is still a habit. One the user has
            // put down for `staleLead` longer than the challenger gets the score
            // comparison unweighted — see the header. Compared, never subtracted:
            // `idle` may be `.infinity` for an item with no history at all, and
            // ∞ − ∞ is NaN, which fails every comparison and would silently mean
            // the OPPOSITE of the sentinel's intent.
            // A challenger with no history of its own cannot claim to be the
            // fresher of the two, so it never collects the waiver — which also
            // makes the ∞-vs-∞ tie fall the safe way, in favour of the incumbent.
            let incumbentIdle = idles[weakest.key] ?? 0
            let stale = challenger.idle.isFinite && incumbentIdle >= challenger.idle + staleLead
            let margin = stale ? 1.0 : promoteMargin
            // In place, at the incumbent's own index: every other slot keeps the
            // number the user's hand has learned.
            if challenger.score > (scores[weakest.key] ?? 0) * margin,
               let at = order.firstIndex(of: weakest) {
                order[at] = Slot(key: challenger.key)
                promoted = true
            }
        }

        // One change per summon, and membership outranks position: a strip that
        // just gained or lost a tile has already given the eye something to
        // re-learn, and correcting an inversion in the same breath is the
        // reshuffle this whole file exists to prevent.
        guard !promoted, !membershipChanged else { return order }
        return correctingOneInversion(order, scores: scores)
    }

    // Swap the DEEPEST qualifying adjacent pair, or nothing. Deepest, not
    // largest: it takes the first pair that clears `reorderMargin` scanning up
    // from the bottom, so a 10× inversion higher on the strip waits its turn
    // behind a 2.1× one below it. Cheaper to reason about, and it means the
    // motion always starts at the end the eye is least attached to.
    //
    // Bottom-up, so a strong tile buried at the end climbs one slot per summon
    // rather than teleporting — six summons to cross a seven-tile strip in the
    // case this was written for, one badly-placed tile among sane ones. That is
    // the CASE's bound, not the function's: this is a bubble sort with one pass
    // per summon, so a thoroughly scrambled seven-tile strip can take up to 21
    // summons to settle, moving two ⌘-numbers each time. Acceptable as a one-off
    // cure for a strip seeded wrong months ago — and the reason the margin is
    // 2.0 rather than something a near-tie could trip. It stops the moment no
    // pair clears it, which is what makes this converge instead of stirring.
    private static func correctingOneInversion(_ order: [Slot],
                                               scores: [String: Double]) -> [Slot] {
        // A slot waiting out a miss has no score, and a missing score is not a
        // low score — the same rule the promotion follows. Sit the summon out.
        guard order.allSatisfy({ scores[$0.key] != nil }) else { return order }
        var order = order
        for i in stride(from: order.count - 1, to: 0, by: -1) {
            guard let below = scores[order[i].key], let above = scores[order[i - 1].key],
                  below > above * reorderMargin else { continue }
            order.swapAt(i, i - 1)
            return order
        }
        return order
    }
}

// The persisted slot order. Read once when the daemon builds its state and
// written ONLY when the order actually changes — which, by construction above,
// is a rare event — and then off the main thread, because the caller is the
// ⌘Space keystroke and that path may not touch the disk.
final class StageSlotStore {
    private var order: [StageSlots.Slot] = []
    private let path: URL
    private let queue = DispatchQueue(label: "co.hausfold.pounce.stage-slots", qos: .utility)

    init(filename: String = "stage-slots.json") {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent(filename)
        guard let raw = try? Data(contentsOf: path) else { return }
        if let decoded = try? JSONDecoder().decode([StageSlots.Slot].self, from: raw) {
            order = decoded
        } else if let plain = try? JSONDecoder().decode([String].self, from: raw) {
            // The bare key list this file held before slots could wait out a
            // miss. Same order, no credit spent.
            order = plain.map { StageSlots.Slot(key: $0) }
        }
    }

    // The keys to draw, in slot order — which is the slots MINUS any that are
    // waiting out a miss, since a tile needs an item to be. The full order,
    // credit included, stays here and on disk, so a source that was merely cold
    // finds its position again on the next summon.
    func resolve(candidates: [(key: String, score: Double, idle: Double)], slots: Int) -> [String] {
        let next = StageSlots.resolve(previous: order, candidates: candidates, slots: slots)
        if next != order {
            order = next
            queue.async { [path] in
                guard let encoded = try? JSONEncoder().encode(next) else { return }
                try? encoded.write(to: path, options: .atomic)
            }
        }
        let live = Set(candidates.map { $0.key })
        return next.map { $0.key }.filter { live.contains($0) }
    }
}
