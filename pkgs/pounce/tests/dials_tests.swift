import Foundation

// Dials (--dial): the spec grammar, the committed-values encoding, and the
// pure half of the sticky memory. The file I/O wrapper (DialMemory) is a
// read/decode/write shell over Dial.applying and stays untested here, like
// Frecency's.

func runDialsTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // The canonical single dial.
    let one = Dial.parse("model=sonnet|opus|haiku")
    expect(one.count == 1, "one segment parses to one dial")
    expect(one.first?.name == "model", "dial keeps its name")
    expect(one.first?.options == ["sonnet", "opus", "haiku"], "options keep declaration order")
    expect(one.first?.value == "sonnet", "a fresh dial opens on the first option")

    // Several dials in one spec; whitespace around tokens is noise.
    let two = Dial.parse(" model = sonnet | opus ; visibility = public | private ")
    expect(two.count == 2, "`;` separates dials")
    expect(two.last?.name == "visibility" && two.last?.options == ["public", "private"],
           "second dial parses independently")

    // parse() is total: malformed segments drop, the rest survive.
    expect(Dial.parse("").isEmpty, "empty spec parses to no dials")
    expect(Dial.parse("nonsense").isEmpty, "a segment with no `=` drops")
    expect(Dial.parse("=a|b").isEmpty, "an unnamed dial drops")
    expect(Dial.parse("model=solo").isEmpty, "a single option is not a dial")
    expect(Dial.parse("model=a|a").isEmpty, "two identical options are one option")
    expect(Dial.parse("model=a|b;junk;mode=x|y").count == 2,
           "a malformed middle segment doesn't take its neighbours with it")

    // A value may contain `=` (only the first one splits the segment).
    let eq = Dial.parse("flag=--opt=1|--opt=2")
    expect(eq.first?.options == ["--opt=1", "--opt=2"], "only the first `=` names the dial")

    // Encoding reads back current values in declaration order.
    var dials = Dial.parse("model=sonnet|opus|haiku;visibility=public|private")
    dials[0].index = 1
    expect(Dial.encode(dials) == "model=opus;visibility=public",
           "encode() emits name=value `;`-joined in declaration order")

    // Sticky memory: a remembered value that still exists is restored; one
    // that vanished from the option set is ignored; the key is the whole
    // segment, so a changed option set forgets.
    let fresh = Dial.parse("model=sonnet|opus|haiku")
    let recalled = Dial.applying(
        memory: ["model=sonnet|opus|haiku": "haiku"], to: fresh)
    expect(recalled.first?.value == "haiku", "memory restores the last-committed value")
    let stale = Dial.applying(
        memory: ["model=sonnet|opus|haiku": "gone"], to: fresh)
    expect(stale.first?.value == "sonnet", "a value no longer offered is ignored")
    let reshaped = Dial.applying(
        memory: ["model=sonnet|opus": "opus"], to: fresh)
    expect(reshaped.first?.value == "sonnet", "a changed option set starts fresh")

    // The clamp in `value` (a decoded index is not trusted).
    var wild = Dial(name: "x", options: ["a", "b"], index: 99)
    expect(wild.value == "b", "an out-of-range index clamps to the last option")
    wild.index = -3
    expect(wild.value == "a", "a negative index clamps to the first option")

    if failures == 0 { print("ok — all dials tests passed") }
    return failures
}
