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
    // two of genuinely using something new, and never by noise.
    static let promoteMargin = 1.5

    // Consecutive summons an incumbent may be missing from the item list before
    // it counts as gone rather than as not-loaded-yet. Three is enough to ride
    // out a cold source (which warms within one summon) while still freeing an
    // uninstalled app's slot within seconds of actual use.
    static let evictAfterMisses = 3

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
    // positive habit score and no minimum query length.
    //
    // Pure, so the whole promotion rule is testable without a clock or a disk.
    static func resolve(previous: [Slot],
                        candidates: [(key: String, score: Double)],
                        slots: Int) -> [Slot] {
        guard slots > 0 else { return [] }
        var scores: [String: Double] = [:]
        for c in candidates where scores[c.key] == nil { scores[c.key] = c.score }

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

        // …and the promotion, at most one per summon. Only an incumbent that
        // actually turned up can be displaced: one waiting out a miss has no
        // score to be compared against, and letting a challenger take its slot
        // on that basis is exactly the eviction-on-absence this guards.
        let present = order.filter { scores[$0.key] != nil }
        guard order.count == slots,
              let weakest = present.min(by: { (scores[$0.key] ?? 0) < (scores[$1.key] ?? 0) }),
              let challenger = candidates.first(where: { !seen.contains($0.key) })
        else { return order }
        guard challenger.score > (scores[weakest.key] ?? 0) * promoteMargin else { return order }
        // In place, at the incumbent's own index: every other slot keeps the
        // number the user's hand has learned.
        if let at = order.firstIndex(of: weakest) { order[at] = Slot(key: challenger.key) }
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
    func resolve(candidates: [(key: String, score: Double)], slots: Int) -> [String] {
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
