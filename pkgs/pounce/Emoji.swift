import AppKit
import CoreText

// MARK: - Emoji

// What kind of character a picker row holds. The picker is one grid over both
// datasets — you type "command" and get ⌘ without first deciding whether the
// thing you want is an emoji — but the two render and rank differently, so the
// row has to know which it is.
enum GlyphKind {
    case emoji
    case symbol
}

struct EmojiEntry: Identifiable {
    let c: String          // the glyph
    let name: String
    let keywords: String
    let search: String     // precomputed "name keywords", lowercased
    let kind: GlyphKind
    var id: String { c }

    // "U+2318", or every scalar for a multi-codepoint sequence. Shown in the
    // footer for symbols, where the codepoint is often the thing you actually
    // came for.
    var codepoints: String {
        c.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
}

// Loads the two bundled datasets:
//
//   emoji.json    the vendored emoji superset, filtered to the glyphs the
//                 running macOS can actually render (see `renders`).
//   symbols.json  a hand-curated set of plain-text Unicode symbols — the mac
//                 modifier keys (⌘ ⌥ ⇧ ⌃), arrows, math, typography, box
//                 drawing. These are ordinary characters, so they paste into
//                 anything; SF Symbols would be private-use glyphs that render
//                 as tofu outside Apple apps, which is why the dataset is
//                 codepoints and not an icon font.
//
// Symbols deliberately SKIP the emoji-font filter: they are drawn by the UI
// font, not Apple Color Emoji, so `renders` would reject every one of them.
// They need no OS-version filtering either — the curated set is stable
// codepoints (Unicode 1.1–3.2, plus a few currency signs), verified at
// authoring time to have no emoji-presentation variant and so never to collide
// with or recolor against emoji.json.
final class EmojiStore {
    static let shared = EmojiStore()
    let all: [EmojiEntry]

    private init() {
        var entries: [EmojiEntry] = []

        if let url = Bundle.main.url(forResource: "emoji", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let probeFont = NSFont(name: "Apple Color Emoji", size: 24)
            entries += arr.compactMap { o -> EmojiEntry? in
                guard let c = o["c"] as? String, let n = o["n"] as? String else { return nil }
                // If the emoji font is somehow unavailable, don't filter at all.
                if let f = probeFont, !EmojiStore.renders(c, font: f) { return nil }
                let k = (o["k"] as? String) ?? ""
                return EmojiEntry(c: c, name: n, keywords: k,
                                  search: "\(n) \(k)".lowercased(), kind: .emoji)
            }
        }

        if let url = Bundle.main.url(forResource: "symbols", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            entries += arr.compactMap { o -> EmojiEntry? in
                guard let c = o["c"] as? String, let n = o["n"] as? String else { return nil }
                let k = (o["k"] as? String) ?? ""
                return EmojiEntry(c: c, name: n, keywords: k,
                                  search: "\(n) \(k)".lowercased(), kind: .symbol)
            }
        }

        all = entries
    }

    // Supported on this OS == every run is still drawn by Apple Color Emoji.
    // CoreText falls back to another font for any glyph the emoji font lacks
    // (e.g. emoji newer than the installed macOS), so a fallback run means the
    // glyph isn't in this OS's set. This allows multi-glyph ligatures (gendered
    // couples, families) while dropping tofu — no Unicode-version table needed.
    private static func renders(_ s: String, font: NSFont) -> Bool {
        let attr = NSAttributedString(string: s, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return false }
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attrs[kCTFontAttributeName as String] else { return false }
            if CTFontCopyPostScriptName(runFont as! CTFont) as String != "AppleColorEmoji" {
                return false
            }
        }
        return true
    }

    func warm() { DispatchQueue.global(qos: .utility).async { _ = EmojiStore.shared.all } }
}
