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
// The one thing that evicts instantly is an item that no longer exists — an
// uninstalled app, a deleted command — because a slot pointing at nothing is
// not stability, it is a hole.
//
// Foundation-only (`resolve` is pure), so tests/run.sh compiles it.
enum StageSlots {
    // How much better a challenger must be than the weakest incumbent to take
    // its slot. 1.5 is roughly "half again the habit" — reached in a week or
    // two of genuinely using something new, and never by noise.
    static let promoteMargin = 1.5

    // The new slot order, given the previous one and today's candidates.
    //
    // `candidates` must be sorted by score, strongest first, and must contain
    // only items eligible to BE a tile — see DaemonState.load, which requires a
    // positive habit score and no minimum query length.
    //
    // Pure, so the whole promotion rule is testable without a clock or a disk.
    static func resolve(previous: [String],
                        candidates: [(key: String, score: Double)],
                        slots: Int) -> [String] {
        guard slots > 0 else { return [] }
        var scores: [String: Double] = [:]
        for c in candidates where scores[c.key] == nil { scores[c.key] = c.score }

        // Incumbents that still exist, in their existing order. Deduped: a
        // hand-edited or half-written file must not be able to put one item in
        // two slots.
        var seen = Set<String>()
        var order = previous.filter { key in
            guard scores[key] != nil, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
        if order.count > slots { order = Array(order.prefix(slots)) }

        // Empty slots — a first run, a raised `stage.tiles`, an eviction — fill
        // from the strongest candidates not already placed. This is the only
        // path that adds more than one tile at a time, and it has to be: there
        // is nothing to be stable about yet.
        for c in candidates where order.count < slots {
            guard !seen.contains(c.key) else { continue }
            seen.insert(c.key)
            order.append(c.key)
        }

        // …and the promotion, at most one per summon.
        guard order.count == slots,
              let weakest = order.min(by: { (scores[$0] ?? 0) < (scores[$1] ?? 0) }),
              let challenger = candidates.first(where: { !seen.contains($0.key) })
        else { return order }
        let incumbentScore = scores[weakest] ?? 0
        guard challenger.score > incumbentScore * promoteMargin else { return order }
        // In place, at the incumbent's own index: every other slot keeps the
        // number the user's hand has learned.
        if let at = order.firstIndex(of: weakest) { order[at] = challenger.key }
        return order
    }
}

// The persisted slot order. Read once when the daemon builds its state and
// written ONLY when the order actually changes — which, by construction above,
// is a rare event — and then off the main thread, because the caller is the
// ⌘Space keystroke and that path may not touch the disk.
final class StageSlotStore {
    private var order: [String] = []
    private let path: URL
    private let queue = DispatchQueue(label: "co.hausfold.pounce.stage-slots", qos: .utility)

    init(filename: String = "stage-slots.json") {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent(filename)
        if let raw = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode([String].self, from: raw) {
            order = decoded
        }
    }

    func resolve(candidates: [(key: String, score: Double)], slots: Int) -> [String] {
        let next = StageSlots.resolve(previous: order, candidates: candidates, slots: slots)
        guard next != order else { return next }
        order = next
        queue.async { [path] in
            guard let encoded = try? JSONEncoder().encode(next) else { return }
            try? encoded.write(to: path, options: .atomic)
        }
        return next
    }
}
