import Foundation

// The list algebra behind `"fnKey": "remap"`. What matters here isn't that we can
// build our own entry — it's that we never lose someone else's. UserKeyMapping is
// one shared list: a Caps→F18 leader from a dotfiles rebuild, a Karabiner
// mapping, and pounce's Fn→F19 all live in it, and a `--set` writes the WHOLE
// list. Dropping a stranger's entry here would silently break a key the user
// never asked us to touch.
func runFunctionKeyRemapTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    let caps = FunctionKeyRemap.Entry(src: 0x700000039, dst: 0x70000006D)   // Caps → F18
    let ours = FunctionKeyRemap.Entry(src: FunctionKeyRemap.fnUsage,
                                      dst: FunctionKeyRemap.targetUsage)

    // hidutil prints an old-style plist, keys in whatever order it likes.
    let output = """
    (
            {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771129;
        },
            {
            HIDKeyboardModifierMappingSrc = 1095216660483;
            HIDKeyboardModifierMappingDst = 30064771182;
        }
    )
    """
    expect(FunctionKeyRemap.parse(output) == [caps, ours], "parses both entries, either key order")
    expect(FunctionKeyRemap.parse("") == [], "an unset mapping parses as empty, not as garbage")
    expect(FunctionKeyRemap.parse("(\n)") == [], "an empty list parses as empty")
    // A half-written entry is not a mapping we should act on.
    expect(FunctionKeyRemap.parse("({HIDKeyboardModifierMappingSrc = 7;})") == [],
           "an entry missing its destination is skipped")

    expect(FunctionKeyRemap.adding(to: [caps]) == [caps, ours], "adding keeps the caps leader")
    expect(FunctionKeyRemap.adding(to: [caps, ours]) == [caps, ours],
           "adding twice is idempotent — no duplicate Fn entry")
    // A stale Fn mapping (ours from a crashed run, or a foreign one) must lose:
    // two entries with the same source would leave which one wins to hidutil.
    let stale = FunctionKeyRemap.Entry(src: FunctionKeyRemap.fnUsage, dst: 0x700000029)
    expect(FunctionKeyRemap.adding(to: [stale, caps]) == [caps, ours],
           "an existing Fn mapping is replaced, not stacked")

    expect(FunctionKeyRemap.removing(from: [caps, ours]) == [caps],
           "removing gives back exactly the other tools' entries")
    expect(FunctionKeyRemap.removing(from: [caps]) == [caps],
           "removing when we were never installed changes nothing")

    expect(FunctionKeyRemap.isMapped([caps, ours]), "isMapped sees our entry")
    expect(!FunctionKeyRemap.isMapped([caps]), "isMapped is false with only foreign entries")
    expect(!FunctionKeyRemap.isMapped([stale]),
           "an Fn mapping pointing somewhere else is NOT ours — pressing Fn wouldn't reach us")

    // The payload is what hidutil actually receives; a shape change here is a
    // silently-not-applied remap, so pin it exactly.
    expect(FunctionKeyRemap.payload([ours]) ==
           #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":1095216660483,"HIDKeyboardModifierMappingDst":30064771182}]}"#,
           "payload renders the JSON hidutil expects")
    expect(FunctionKeyRemap.payload([]) == #"{"UserKeyMapping":[]}"#,
           "an empty payload clears the list rather than being malformed")

    // Round trip: what we'd write, re-read, is what we meant.
    expect(FunctionKeyRemap.parse(output) == FunctionKeyRemap.adding(to: [caps]),
           "parse ∘ add round-trips against real hidutil output")

    if failures == 0 { print("ok — all Fn remap tests passed") }
    return failures
}
