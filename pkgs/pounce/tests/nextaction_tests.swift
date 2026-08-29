import Foundation

// NextActionStore's pure half: given what usually follows one item, is there a
// prediction confident enough to draw a card for? The instance half — the JSON
// file, the wall clock and the `last` trace that survives a process — is what
// this was split out from.
func runNextActionTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    let now = 1_756_000_000.0
    func count(_ weight: Double, _ ago: Double = 0) -> NextActionStore.Count {
        .init(weight: weight, lastUsed: now - ago)
    }

    // MARK: the two bars

    // A clear habit: eight of thirteen follow-ups agree. p = 0.62.
    let habit = NextActionStore.predict(
        ["app:/Applications/Cursor.app": count(8),
         "app:/Applications/Safari.app": count(3),
         "cmd:ports": count(2)], now: now)
    expect(habit?.key == "app:/Applications/Cursor.app", "the strongest continuation wins")
    expect((habit?.probability ?? 0) > 0.6, "…and its share is reported with it")
    expect(habit?.evidence == 13, "evidence is the n behind the p")

    // A coin flip drawn on the panel is furniture with a name on it.
    expect(NextActionStore.predict(["a": count(6), "b": count(6)], now: now) == nil,
           "a split between two continuations is not a prediction")
    expect(NextActionStore.predict(["a": count(5), "b": count(3), "c": count(3)], now: now) == nil,
           "…and neither is a plurality below the bar")

    // Twice in a row is not a habit, however unanimous.
    expect(NextActionStore.predict(["a": count(2)], now: now) == nil,
           "two follow-ups is not enough evidence, even at p = 1")
    expect(NextActionStore.predict(["a": count(5)], now: now) != nil,
           "…five is, which is where the bar was set")
    expect(NextActionStore.predict([:], now: now) == nil, "nothing recorded predicts nothing")

    // MARK: decay

    // The pairs decay on the long half-life, like every other habit here — so a
    // workflow you have not run in a season stops being offered, and one you
    // ran last week does not.
    let stale = NextActionStore.predict(
        ["a": count(9, NextActionStore.halfLife * 4)], now: now)
    expect(stale == nil, "a habit four half-lives old no longer clears the evidence bar")
    let fresh = NextActionStore.predict(["a": count(9, 86400)], now: now)
    expect(fresh != nil, "…a day old is untouched")

    // Decay is per-pair, from each pair's own last use: a continuation you have
    // moved on from should lose to the one you moved TO, even on a smaller
    // lifetime count.
    let switched = NextActionStore.predict(
        ["old": count(12, NextActionStore.halfLife * 2),
         "new": count(6)], now: now)
    expect(switched?.key == "new", "the continuation you use NOW wins the one you used to")

    // MARK: warm — the window, which the writer and the reader share

    let trace = NextActionStore.Trace(key: "cmd:a", at: now)
    expect(NextActionStore.warm(trace, now: now + 30),
           "half a minute later you are still in the middle of something")
    expect(NextActionStore.warm(trace, now: now + NextActionStore.window),
           "…and right up to the window's edge")
    expect(!NextActionStore.warm(trace, now: now + NextActionStore.window + 1),
           "past it, the next thing you do is a new thought, not a follow-up")
    expect(!NextActionStore.warm(nil, now: now), "nothing committed yet is not a chain")
    expect(!NextActionStore.warm(trace, now: now - 60),
           "a trace from the future (a clock change, a restored home) is not evidence")

    // MARK: capped

    var nexts: [String: NextActionStore.Count] = [:]
    for i in 0..<NextActionStore.maxNexts + 2 { nexts["old\(i)"] = count(Double(10 + i)) }
    nexts["fresh"] = count(1)
    let kept = NextActionStore.capped(nexts, keeping: "fresh", now: now)
    expect(kept.count == NextActionStore.maxNexts, "a predecessor's continuations are bounded")
    expect(kept["fresh"] != nil,
           "the pair just recorded survives the trim, or a workflow that changed " +
           "could never be learned (QueryMemory.capped's reason, verbatim)")
    expect(kept["old0"] == nil, "…and the weakest of the others is what it costs")

    if failures == 0 { print("ok — NextAction prediction tests passed") }
    return failures
}
