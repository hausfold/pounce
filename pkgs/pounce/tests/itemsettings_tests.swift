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
    check(bindings.first(where: { $0.target == "mode:clipboard" })?.spec.display == "cmd+shift+v",
          "a mode: target carries its combo through")
    check(bindings.first(where: { $0.target == "app:/Applications/Ghostty.app" })?.spec
            == HotKeySpec(key: "t", modifiers: ["opt"]),
          "the object form works inside the map too")

    // A disabled item keeps its hotkey: binding a key to something you keep out
    // of the palette is a deliberate setup, not a contradiction.
    let hidden = ItemSettings.parse(["cmd:lock": ["enabled": false, "hotkey": "ctrl+l"]] as Any)
    check(!hidden.isEnabled("cmd:lock"), "the hidden item is disabled")
    check(hidden.bindings.count == 1, "disabling an item does not disarm its hotkey")

    if failures == 0 { print("ok — all ItemSettings tests passed") }
    return failures
}
