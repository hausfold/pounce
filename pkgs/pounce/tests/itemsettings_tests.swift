// Unit tests for config.json's `items` map (ItemSettings.swift) — the per-item
// enable / alias / hotkey schema. Worth covering here rather than by hand
// because the daemon reads hotkeys ONCE at startup: a parsing slip shows up as
// a key that silently does nothing, which is expensive to notice.
//
// Named with a _tests suffix (see tests/run.sh) so it can't collide with
// ItemSettings.swift on a case-insensitive filesystem.

import Foundation

func runItemSettingsTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // MARK: HotKeySpec — the string form

    check(HotKeySpec.parse("opt+e") == HotKeySpec(key: "e", modifiers: ["opt"]),
          "single modifier parses")
    check(HotKeySpec.parse("cmd+shift+v") == HotKeySpec(key: "v", modifiers: ["cmd", "shift"]),
          "the last segment is the key, the rest are modifiers")
    check(HotKeySpec.parse("F") == HotKeySpec(key: "f", modifiers: []),
          "a bare key needs no modifier and lowercases")
    check(HotKeySpec.parse("Fn") == HotKeySpec(key: "fn", modifiers: []),
          "the modifier-only Fn binding survives parsing for the event-tap path")
    check(HotKeySpec.parse("CMD + Shift + V") == HotKeySpec(key: "v", modifiers: ["cmd", "shift"]),
          "spacing and case are tolerated")

    // Nothing left to bind → nil, so the daemon skips it instead of registering
    // a combo the user never meant.
    check(HotKeySpec.parse("") == nil, "empty string is not a binding")
    check(HotKeySpec.parse("cmd+") == nil, "modifier with no key is not a binding")

    // MARK: HotKeySpec — the object form the `hotkey`/`windows` blocks use

    check(HotKeySpec.parse(["key": "v", "modifiers": ["cmd", "shift"]] as Any)
            == HotKeySpec(key: "v", modifiers: ["cmd", "shift"]),
          "object form parses to the same thing as the string form")
    check(HotKeySpec.parse(["modifiers": ["cmd"]] as Any) == nil,
          "object form without a key is not a binding")
    check(HotKeySpec.parse(nil) == nil, "a missing hotkey is not a binding")
    check(HotKeySpec.parse(42 as Any) == nil, "a nonsense hotkey value is not a binding")

    check(HotKeySpec(key: "v", modifiers: ["cmd", "shift"]).display == "cmd+shift+v",
          "display round-trips the string form")
    check(HotKeySpec(key: "f5", modifiers: []).display == "f5",
          "display of a modifier-less binding is just the key")

    // MARK: Sequences — the leader form

    // The distinction the whole leader feature rests on: whitespace separates
    // STEPS, "+" separates modifiers, and spacing around "+" is not a separator.
    check(HotKeySequence.parse("opt+e")?.steps == [HotKeySpec(key: "e", modifiers: ["opt"])],
          "one step is a plain chord")
    check(HotKeySequence.parse("opt+e")?.isLeader == false, "a single step is not a leader")
    check(HotKeySequence.parse("opt+space e")?.steps
            == [HotKeySpec(key: "space", modifiers: ["opt"]),
                HotKeySpec(key: "e", modifiers: [])],
          "two steps: leader then a bare key")
    check(HotKeySequence.parse("opt+space e")?.isLeader == true, "two steps is a leader")
    check(HotKeySequence.parse("cmd + shift + v")?.steps.count == 1,
          "spacing around + does NOT split steps")
    check(HotKeySequence.parse("cmd+k cmd+c")?.steps
            == [HotKeySpec(key: "k", modifiers: ["cmd"]),
                HotKeySpec(key: "c", modifiers: ["cmd"])],
          "a second step may carry its own modifiers")
    check(HotKeySequence.parse("opt+space g s")?.steps.count == 3, "three steps parse")
    check(HotKeySequence.parse(["opt+space", "e"] as Any)?.steps.count == 2,
          "the array form records step by step")
    check(HotKeySequence.parse("opt+space  e")?.steps.count == 2, "runs of spaces are one separator")
    check(HotKeySequence.parse("opt+space +")  == nil, "a malformed step voids the whole sequence")
    check(HotKeySequence.parse("")  == nil, "an empty sequence is not a binding")
    check(HotKeySequence.parse(["opt+space", ""] as Any) == nil,
          "an empty element voids the array form")
    check(HotKeySequence.parse(["key": "v", "modifiers": ["cmd"]] as Any)?.steps.count == 1,
          "the object form is a single step")
    check(HotKeySequence.parse("opt+space e")?.display == "opt+space e",
          "display round-trips the sequence")

    // MARK: Targets

    check(ItemTarget.parse("cmd:emoji") == .command("emoji"), "cmd: names a command id")
    check(ItemTarget.parse("app:/Applications/Foo.app") == .app("/Applications/Foo.app"),
          "app: names a path")
    check(ItemTarget.parse("mode:clipboard") == .mode("clipboard"), "mode: names a built-in window")
    check(ItemTarget.parse("mode:nope") == nil, "an unknown mode is not a target")
    check(ItemTarget.parse("nonsense") == nil, "a prefix-less string is not a target")
    check(ItemTarget.parse("cmd:") == nil, "an empty command id is not a target")
    check(ItemTarget.parse("") == nil, "an empty string is not a target")

    // problem() is what lets `pounce run` exit non-zero on a typo instead of
    // acknowledging a key that will do nothing.
    check(ItemTarget.problem(with: "cmd:emoji") == nil, "a well-formed target has no problem")
    // Deliberately shape-only: the script may not exist yet, and that's warned
    // about separately rather than refused here.
    check(ItemTarget.problem(with: "cmd:not-installed-yet") == nil,
          "an unknown command id is still a well-formed target")
    check(ItemTarget.problem(with: "") == "empty target", "an empty target is named as such")
    check(ItemTarget.problem(with: "mode:nope")?.contains("no built-in mode") == true,
          "a bad mode says so and lists the real ones")
    check(ItemTarget.problem(with: "mode:nope")?.contains("mode:clipboard") == true,
          "and the list comes from ItemTarget.modes")
    check(ItemTarget.problem(with: "emoji")?.contains("not an item key") == true,
          "a missing prefix is named as such")

    // MARK: The binding tree

    // Sequences sharing a leader must share ONE node — that's what lets the
    // daemon register ⌥Space once and grab e/c only while it's armed.
    let (root, conflicts) = HotKeyNode.build([
        (target: "cmd:emoji", sequence: HotKeySequence.parse("opt+space e")!),
        (target: "mode:clipboard", sequence: HotKeySequence.parse("opt+space c")!),
        (target: "cmd:lock", sequence: HotKeySequence.parse("opt+l")!),
    ])
    check(conflicts.isEmpty, "a well-formed set has no conflicts")
    check(root.children.count == 2, "⌥Space and ⌥L are the two first steps")
    check(root.children["opt+space"]?.children.count == 2, "both sequences share the one leader node")
    check(root.children["opt+space"]?.isLeaf == false, "a leader is not itself a leaf")
    check(root.children["opt+l"]?.target == "cmd:lock", "a one-step binding is a leaf of the root")
    check(HotKeyNode.targets(under: root.children["opt+space"]!).sorted()
            == ["cmd:emoji", "mode:clipboard"],
          "targets(under:) finds everything a leader reaches")

    // Prefix collisions can't be resolved silently — one of the two bindings
    // would be permanently dead, so the daemon has to be able to say which.
    let (_, shadowed) = HotKeyNode.build([
        (target: "cmd:a", sequence: HotKeySequence.parse("opt+space")!),
        (target: "cmd:b", sequence: HotKeySequence.parse("opt+space e")!),
    ])
    check(shadowed.count == 1, "a sequence extending a shorter one is reported")
    check(shadowed.first?.contains("can never fire") == true, "and says why")

    // Same in the other insertion order: the shorter arrives second.
    let (_, blocked) = HotKeyNode.build([
        (target: "cmd:b", sequence: HotKeySequence.parse("opt+space e")!),
        (target: "cmd:a", sequence: HotKeySequence.parse("opt+space")!),
    ])
    check(blocked.count == 1, "order doesn't hide a prefix collision")

    let (_, dupes) = HotKeyNode.build([
        (target: "cmd:a", sequence: HotKeySequence.parse("opt+space e")!),
        (target: "cmd:b", sequence: HotKeySequence.parse("opt+space e")!),
    ])
    check(dupes.count == 1, "two items on the identical sequence is reported")
    check(dupes.first?.contains("bound twice") == true, "and named as a duplicate")

    // MARK: The map

    let raw: [String: Any] = [
        "cmd:emoji": ["alias": "emo", "hotkey": "opt+e"],
        "cmd:brew-services": ["enabled": false],
        "app:/Applications/Ghostty.app": ["hotkey": ["key": "t", "modifiers": ["opt"]]],
        "mode:clipboard": ["hotkey": "cmd+shift+v"],
        "cmd:junk": "not-an-object",          // skipped, must not take the map down
        "cmd:blank-alias": ["alias": ""],
    ]
    let items = ItemSettings.parse(raw)

    check(items.entries.count == 5, "the malformed entry is skipped, the rest survive")
    check(!items.isEmpty, "a populated map is not empty")
    check(ItemSettings.parse(nil).isEmpty, "a missing `items` key yields an empty map")

    // enabled: absent means on — an untouched config must behave as before.
    check(items.isEnabled("cmd:emoji"), "an entry without `enabled` stays enabled")
    check(!items.isEnabled("cmd:brew-services"), "enabled:false disables")
    check(items.isEnabled("cmd:never-mentioned"), "an unlisted item is enabled")

    check(items.alias(for: "cmd:emoji") == "emo", "alias reads back")
    check(items.alias(for: "cmd:blank-alias") == nil, "an empty alias is treated as none")
    check(items.alias(for: "cmd:brew-services") == nil, "no alias means nil, not empty string")

    // Bindings: only entries carrying a hotkey, sorted by target so the daemon's
    // registration order (and `pounce doctor`'s output) is deterministic.
    let bindings = items.bindings
    check(bindings.count == 3, "only entries with a hotkey become bindings")
    check(bindings.map(\.target) == ["app:/Applications/Ghostty.app", "cmd:emoji", "mode:clipboard"],
          "bindings come back sorted by target")
    check(bindings.first(where: { $0.target == "mode:clipboard" })?.sequence.display == "cmd+shift+v",
          "a mode: target carries its combo through")
    check(bindings.first(where: { $0.target == "app:/Applications/Ghostty.app" })?.sequence.steps
            == [HotKeySpec(key: "t", modifiers: ["opt"])],
          "the object form works inside the map too")

    // A disabled item keeps its hotkey: binding a key to something you keep out
    // of the palette is a deliberate setup, not a contradiction.
    let hidden = ItemSettings.parse(["cmd:lock": ["enabled": false, "hotkey": "ctrl+l"]] as Any)
    check(!hidden.isEnabled("cmd:lock"), "the hidden item is disabled")
    check(hidden.bindings.count == 1, "disabling an item does not disarm its hotkey")

    if failures == 0 { print("ok — all ItemSettings tests passed") }
    return failures
}
