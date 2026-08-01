// Integrity checks for symbols.json — the curated plain-text symbol dataset the
// emoji picker merges in alongside emoji.json (see Emoji.swift).
//
// EmojiStore itself is AppKit/CoreText (it probes the emoji font), so it can't
// join this Foundation-only suite; the dataset can, and the dataset is what a
// hand edit breaks. A duplicate glyph collapses two LazyVGrid rows onto one id;
// a glyph that also exists in emoji.json does the same across the two files —
// both are silent in the UI and loud here.
//
// What can't be checked here (needs CoreText, verified at authoring time
// instead): that no symbol has an emoji-presentation variant Apple Color Emoji
// would claim and recolor.

import Foundation

func runSymbolsTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // run.sh cd's to pkgs/pounce, next to both datasets.
    func load(_ name: String) -> [[String: Any]]? {
        guard let data = FileManager.default.contents(atPath: name),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return arr
    }

    guard let symbols = load("symbols.json") else {
        FileHandle.standardError.write(Data("FAIL: symbols.json missing or not valid JSON\n".utf8))
        return 1
    }
    check(symbols.count > 100, "symbols.json has a real dataset (got \(symbols.count))")

    var glyphs = Set<String>()
    var byName: [String: String] = [:]   // name -> glyph
    for o in symbols {
        guard let c = o["c"] as? String, !c.isEmpty else {
            check(false, "every symbol entry has a non-empty \"c\""); continue
        }
        guard let n = o["n"] as? String, !n.isEmpty else {
            check(false, "symbol \(c) has a non-empty \"n\""); continue
        }
        check(glyphs.insert(c).inserted, "symbol \(c) (\(n)) appears only once")
        byName[n] = c
    }

    // Glyph is the row id in the picker's grid, and the frecency key — a glyph
    // in both files would be two rows fighting over one identity.
    if let emoji = load("emoji.json") {
        let emojiGlyphs = Set(emoji.compactMap { $0["c"] as? String })
        let overlap = glyphs.intersection(emojiGlyphs).sorted()
        check(overlap.isEmpty, "no symbol collides with emoji.json (got \(overlap))")
    } else {
        check(false, "emoji.json missing or not valid JSON")
    }

    // The mac modifier keys are the reason this dataset exists: typing
    // "command" has to reach ⌘. Names are what the picker fuzzy-matches, so
    // these are the contract, not decoration.
    check(byName["command"] == "\u{2318}", "\"command\" is ⌘ U+2318")
    check(byName["option"] == "\u{2325}", "\"option\" is ⌥ U+2325")
    check(byName["shift"] == "\u{21E7}", "\"shift\" is ⇧ U+21E7")
    check(byName["control"] == "\u{2303}", "\"control\" is ⌃ U+2303")

    // Search runs over "name keywords" lowercased (EmojiEntry.search), so an
    // uppercase letter in either field is unreachable by a typed query.
    for o in symbols {
        let n = (o["n"] as? String) ?? ""
        let k = (o["k"] as? String) ?? ""
        check(n == n.lowercased(), "symbol name \"\(n)\" is lowercase")
        check(k == k.lowercased(), "keywords for \"\(n)\" are lowercase")
    }

    if failures == 0 { print("ok — all symbols dataset tests passed") }
    return failures
}
