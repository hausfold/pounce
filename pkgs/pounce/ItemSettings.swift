import Foundation

// MARK: - Per-item settings (config.json's `items` map)
//
// The three things you'd otherwise want three config keys for — hide it, give it
// a shorthand, give it a key — expressed as ONE map keyed by an item key. That
// keying is the point: a single entry is exactly one row of a settings list, so
// a UI that edits these mutates one key rather than reconciling three parallel
// arrays.
//
// Foundation-only by design (no AppKit/SwiftUI), like the quick-answer engines,
// so tests/run.sh can compile it — see tests/itemsettings_tests.swift. Settings
// (Config.swift) owns the disk read and hands the raw `items` value here.

// A key + modifier combination, as written anywhere in config.json. Two
// spellings are accepted so neither surface is awkward:
//
//   "opt+e"                            the string form, used in `items`
//   {"key": "e", "modifiers": ["opt"]} the object form, used by the `hotkey`
//                                      and `windows` blocks (which shipped
//                                      before the string form existed)
//
// Both parse to the same thing, so a settings UI can emit whichever it likes and
// a hand-written config can mix them.
struct HotKeySpec: Equatable {
    var key: String
    var modifiers: [String]

    // "cmd+shift+v" → key "v", modifiers ["cmd","shift"]. The LAST segment is
    // the key; everything before it is a modifier. Returns nil when there's no
    // key left to bind ("", "cmd+"), which can never be a usable binding —
    // hence omittingEmptySubsequences: false, so a trailing "+" leaves an empty
    // last segment to reject rather than silently promoting "cmd" to the key.
    static func parse(_ string: String) -> HotKeySpec? {
        let parts = string.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let key = parts.last, !key.isEmpty else { return nil }
        return HotKeySpec(key: key, modifiers: parts.dropLast().filter { !$0.isEmpty })
    }

    static func parse(_ any: Any?) -> HotKeySpec? {
        if let s = any as? String { return parse(s) }
        if let obj = any as? [String: Any] {
            guard let k = obj["key"] as? String, !k.isEmpty else { return nil }
            return HotKeySpec(key: k.lowercased(),
                              modifiers: ((obj["modifiers"] as? [String]) ?? []).map { $0.lowercased() })
        }
        return nil
    }

    // Log/diagnostic form, matching how the shipped blocks are already logged.
    var display: String {
        modifiers.isEmpty ? key : modifiers.joined(separator: "+") + "+" + key
    }
}

// One item's overrides. `enabled` and `alias` apply to things the palette
// LISTS (commands and apps); a "mode:" entry only meaningfully carries a
// hotkey, since no palette row corresponds to it.
struct ItemSetting: Equatable {
    var enabled: Bool = true
    var alias: String?
    var hotkey: HotKeySpec?
}

// The whole `items` map. Entries are keyed by an item's STABLE KEY — the same
// string the frecency store already uses (see PounceItem.frecencyKey), so one
// map covers every kind of thing the palette can address:
//
//   "cmd:<id>"                      a command script (its filename without .sh)
//   "app:/Applications/Foo.app"     an application, by path
//   "mode:<name>"                   a built-in window: launcher, clipboard,
//                                   emoji, screenshots, camera, filesearch
//
//   "items": {
//     "cmd:emoji":                    { "alias": "emo", "hotkey": "opt+e" },
//     "cmd:brew-services":            { "enabled": false },
//     "app:/Applications/Ghostty.app": { "hotkey": "opt+t" },
//     "mode:clipboard":               { "hotkey": "cmd+shift+v" }
//   }
struct ItemSettings {
    var entries: [String: ItemSetting] = [:]

    var isEmpty: Bool { entries.isEmpty }

    // Lenient like the rest of Settings.load: a malformed entry is skipped, not
    // fatal, so one bad line can't cost you the whole map.
    static func parse(_ any: Any?) -> ItemSettings {
        var settings = ItemSettings()
        guard let raw = any as? [String: Any] else { return settings }
        for (key, value) in raw {
            guard let fields = value as? [String: Any] else { continue }
            var entry = ItemSetting()
            if let e = fields["enabled"] as? Bool { entry.enabled = e }
            if let a = fields["alias"] as? String, !a.isEmpty { entry.alias = a }
            entry.hotkey = HotKeySpec.parse(fields["hotkey"])
            settings.entries[key] = entry
        }
        return settings
    }

    // MARK: Lookups
    //
    // Read on the launcher's hot path (once per item per open), so they stay
    // dictionary lookups against the already-parsed map — no re-reading of disk.

    // False only when an entry explicitly says so; an unlisted item is enabled.
    func isEnabled(_ itemKey: String) -> Bool { entries[itemKey]?.enabled ?? true }

    // A user-assigned search alias ("emo" → Emoji Picker), or nil.
    func alias(for itemKey: String) -> String? { entries[itemKey]?.alias }

    // Every item carrying a hotkey, as (target, spec) pairs. The daemon
    // registers these at startup (see DaemonMode.run). Sorted by target so the
    // registration order — and therefore the log and `pounce doctor` — is
    // deterministic rather than dictionary-order roulette.
    var bindings: [(target: String, spec: HotKeySpec)] {
        entries.compactMap { key, entry in entry.hotkey.map { (target: key, spec: $0) } }
            .sorted { $0.target < $1.target }
    }
}
