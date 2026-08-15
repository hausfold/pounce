import Foundation

// MARK: - Drafts
//
// A crash-safe scratch pad for the picker's free-text field.
//
// The palette is a transient, focus-fragile surface: it dies on Esc and on a
// click into any other app. That is exactly right for "pick a row" and exactly
// wrong for "type a paragraph" — and callers like the haus Spawn Agent
// command DO ask you to type a paragraph. Losing it to a stray click is the one
// failure a picker can't apologise for, because the text only ever existed in
// that field.
//
// So a caller that asks for free text can pass `--draft <key>`: every dismissal
// that isn't a commit files the current query under that key, and the caller can
// offer it back later (`pounce drafts <key> …`). Opt-in per invocation — the
// launcher and the filter-style modes have nothing worth keeping.
//
// Foundation-only (no AppKit/SwiftUI) so tests/run.sh compiles it.

struct Draft {
    let stamp: Int      // unix seconds
    let text: String
}

enum Drafts {
    // Enough to cover "I lost the good one three tries ago", few enough that the
    // list stays a list. Oldest are dropped on write.
    static let maxEntries = 20

    // MARK: Paths

    // getenv, not ProcessInfo.environment / NSHomeDirectory: both cache the
    // value they were first asked for, and the store has to follow a HOME that
    // moved (the unit tests point it at a temp dir).
    static var dir: String {
        let home = getenv("HOME").map { String(cString: $0) } ?? NSHomeDirectory()
        return home + "/.local/state/pounce/drafts"
    }

    // A key names a caller's field ("spawn-agent"), and callers are shell
    // scripts — so it reaches us as arbitrary text and must never be able to
    // escape `dir`. Anything outside [A-Za-z0-9_-] folds to a dash; `.` is NOT
    // in that set, which is what keeps `..` out of the result rather than
    // relying on a separate traversal check. Runs of dashes collapse and the
    // ends are trimmed, so a key that folds away entirely becomes "default"
    // rather than an empty (or all-punctuation) filename.
    static func sanitize(_ key: String) -> String {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var out = ""
        for ch in key {
            let mapped = ok.contains(ch) ? ch : "-"
            if mapped == "-" && out.hasSuffix("-") { continue }
            out.append(mapped)
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "default" : out
    }

    static func path(for key: String) -> String {
        dir + "/" + sanitize(key) + ".tsv"
    }

    // MARK: Encoding
    //
    // The store is line-based (one draft per line, `<stamp>\t<text>`) because
    // every consumer downstream is a shell script reading it through `pounce
    // drafts`. A draft, however, is precisely the thing that CONTAINS newlines —
    // that's why the field grew a Shift+Return in the first place. So the text is
    // backslash-escaped on the way in and restored on the way out; the escape is
    // pure and tested rather than a `tr` at the call site that would silently
    // flatten a multi-line prompt into one line.

    static func encode(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        for ch in text {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:   out.append(ch)
            }
        }
        return out
    }

    static func decode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var escaped = false
        for ch in s {
            if escaped {
                switch ch {
                case "n":  out.append("\n")
                case "r":  out.append("\r")
                case "t":  out.append("\t")
                case "\\": out.append("\\")
                // An unknown escape keeps both characters: better to hand back a
                // slightly odd prompt than to eat a literal backslash the user
                // typed before some other letter.
                default:   out.append("\\"); out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    // MARK: Store

    // Newest first — the order every caller wants, and the order `save` writes.
    static func load(key: String) -> [Draft] {
        guard let raw = try? String(contentsOfFile: path(for: key), encoding: .utf8) else {
            return []
        }
        return raw.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: "\t", maxSplits: 1,
                                   omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let stamp = Int(parts[0]) else { return nil }
            let text = decode(parts[1])
            return text.isEmpty ? nil : Draft(stamp: stamp, text: text)
        }
    }

    private static func write(_ drafts: [Draft], key: String) {
        let file = path(for: key)
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let body = drafts.prefix(maxEntries)
            .map { "\($0.stamp)\t\(encode($0.text))" }
            .joined(separator: "\n")
        // Atomic: the daemon writes this from a dismissal while a `pounce drafts`
        // client may be reading it, and a half-written line is a lost draft.
        try? (body + (body.isEmpty ? "" : "\n"))
            .write(toFile: file, atomically: true, encoding: .utf8)
    }

    // Returns false when there was nothing worth keeping — an all-whitespace
    // query, or a repeat of what's already on top (opening and dismissing the
    // same restored draft twice shouldn't grow the list).
    @discardableResult
    static func save(key: String, text: String, now: Int? = nil) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var drafts = load(key: key)
        if drafts.first?.text == text { return false }
        drafts.insert(Draft(stamp: now ?? Int(Date().timeIntervalSince1970), text: text), at: 0)
        write(drafts, key: key)
        return true
    }

    @discardableResult
    static func remove(key: String, index: Int) -> Bool {
        var drafts = load(key: key)
        guard index >= 0 && index < drafts.count else { return false }
        drafts.remove(at: index)
        write(drafts, key: key)
        return true
    }

    static func clear(key: String) {
        try? FileManager.default.removeItem(atPath: path(for: key))
    }

    // MARK: Display helpers
    //
    // Both live here rather than in the CLI branch so the shell never has to
    // fold whitespace or do date math — a draft's preview is one line by
    // construction, which is what keeps a TSV picker row honest.

    static func preview(_ text: String, limit: Int = 90) -> String {
        var folded = ""
        var lastWasSpace = false
        for ch in text {
            if ch.isWhitespace {
                if !lastWasSpace && !folded.isEmpty { folded.append(" ") }
                lastWasSpace = true
            } else {
                folded.append(ch)
                lastWasSpace = false
            }
        }
        while folded.hasSuffix(" ") { folded.removeLast() }
        guard folded.count > limit else { return folded }
        return String(folded.prefix(limit - 1)) + "…"
    }

    static func ago(_ stamp: Int, now: Int) -> String {
        let d = max(0, now - stamp)
        switch d {
        case ..<60:      return "just now"
        case ..<3600:    return "\(d / 60)m ago"
        case ..<86400:   return "\(d / 3600)h ago"
        case ..<(86400 * 7): return "\(d / 86400)d ago"
        default:         return "\(d / (86400 * 7))w ago"
        }
    }
}
