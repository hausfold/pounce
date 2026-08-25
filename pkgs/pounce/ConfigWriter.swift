// Writes ONE setting back into config.json without disturbing anything else in
// it — the other half of ConfigTemplate.
//
// The annotated file `pounce config init` writes is the model this follows
// rather than replaces: every setting present, documented, and commented out,
// where "commented out" IS "at its default". So a settings window changing a
// value doesn't rewrite the file, it uncomments the line and puts the new value
// on it; setting a value back to its default comments the line out again. Your
// prose, your ordering, your own comments and every key pounce has never heard
// of survive untouched, because nothing outside the one line is ever rebuilt.
//
// The alternative — re-serialising the parsed JSON — would have been twenty
// lines instead of two hundred and would have deleted every comment in the file
// the first time anyone clicked a switch. For a file the user is invited to
// edit by hand, that is not a trade worth making.
//
// WHAT IT REFUSES TO DO is as much of the design as what it does. This is a
// LINE editor: it finds the line a setting is on and replaces it. That covers
// the annotated file pounce writes and every hand-written config with one key
// per line, but not a section folded onto one — `"clipboard": { "maxEntries":
// 50 }` has nowhere to put a second line without re-laying-out braces that
// might hold anything. So it says it cannot, and changes nothing. The
// alternative it used to do was worse than useless: it appended a SECOND
// `"clipboard"` object, and since a later duplicate key wins in
// JSONSerialization, the settings in the first one silently stopped applying.
// A settings window that quietly deletes a setting you did not touch is the one
// failure this whole file exists to avoid.
//
// Foundation-only, like ConfigTemplate, so tests/run.sh can compile it and
// prove a round trip still parses.

import Foundation

enum ConfigWriter {
    /// Set `section.key` to a JSON literal, or hand it back to its default.
    ///
    /// - Parameters:
    ///   - text: the whole config file.
    ///   - section: the `{ }` the key lives in, or nil for a top-level key.
    ///   - key: the leaf name.
    ///   - json: the new value, already rendered as JSON (`ConfigSpec.json`),
    ///     or **nil to comment the line out** — which is how a setting goes
    ///     back to its default without leaving a redundant line behind.
    ///   - defaultJSON: what the commented-out line should read when `json` is
    ///     nil. The file's contract is that a commented line documents the
    ///     default, so handing a setting back has to restore that value too,
    ///     not park the last thing you tried behind a `//`. Only the caller
    ///     knows it (ConfigSpec does); nil leaves whatever value was there.
    /// - Returns: the new file text, and the reason it isn't new when the edit
    ///   couldn't be made safely.
    struct Outcome {
        /// The file to write. Identical to what came in when `refused` is set.
        let text: String
        /// Why nothing changed, in a sentence for the user, or nil on success.
        let refused: String?
    }

    static func apply(
        _ text: String, section: String?, key: String, json: String?, default defaultJSON: String? = nil
    ) -> Outcome {
        var lines = text.components(separatedBy: "\n")
        let depths = depthsBefore(lines)

        let range: Range<Int>
        switch searchRange(lines, depths: depths, section: section) {
        case .range(let found):
            range = found
        case .inline:
            // The braces this key lives between open and close on one line.
            // See the note at the top: there is no line to edit and no room to
            // add one, and appending a second object of the same name would
            // shadow everything in the first.
            return Outcome(text: text, refused: section.map {
                "\"\($0)\" is written on a single line in config.json, so pounce can't change "
                + "one setting inside it without re-laying out the rest. Put each key on its own "
                + "line, or change this one in the file."
            } ?? "config.json is written on a single line, so pounce can't change one setting in "
                + "it without rewriting the whole file. Put each key on its own line, or change "
                + "this one in the file.")
        case .missing:
            // The section isn't in the file at all — a hand-written config that
            // never mentioned clipboard, say. Nothing to comment out; a value
            // gets a section of its own.
            guard let json else { return Outcome(text: text, refused: nil) }
            return Outcome(
                text: insertSection(section, key: key, json: json, into: lines, depths: depths),
                refused: nil)
        }

        guard let found = locate(key: key, in: lines, range: range, depths: depths, section: section)
        else {
            guard let json else { return Outcome(text: text, refused: nil) }
            lines.insert(
                "\(insertionIndent(lines, range: range, section: section))\"\(key)\": \(json),",
                at: range.upperBound)
            return Outcome(text: lines.joined(separator: "\n"), refused: nil)
        }

        let indent = leadingWhitespace(lines[found.lowerBound])
        if let json {
            lines.replaceSubrange(found, with: ["\(indent)\"\(key)\": \(json),"])
        } else {
            // Back to the default, which in this file's grammar is a commented
            // line — keeping the prose above it, and keeping the file the kind
            // of file where what's uncommented is what you meant.
            if let defaultJSON {
                lines.replaceSubrange(found, with: commented("\"\(key)\": \(defaultJSON),", indent: indent))
            } else {
                lines.replaceSubrange(found, with: lines[found].map { line in
                    isCommented(line) ? line : "\(indent)// \(line.drop(while: { $0 == " " || $0 == "\t" }))"
                })
            }
        }
        return Outcome(text: lines.joined(separator: "\n"), refused: nil)
    }

    // MARK: - Finding things

    /// The structural depth before each line, plus one final entry for after
    /// the last — counting braces and brackets in the part of the line that is
    /// real JSON, so the commented-out settings that make up most of this file
    /// don't move it.
    private static func depthsBefore(_ lines: [String]) -> [Int] {
        var depths: [Int] = []
        var depth = 0
        for line in lines {
            depths.append(depth)
            for character in structuralPart(line) {
                if character == "{" || character == "[" { depth += 1 }
                if character == "}" || character == "]" { depth -= 1 }
            }
        }
        depths.append(depth)
        return depths
    }

    /// A line with its comment and its string contents removed — what's left is
    /// only the punctuation that nests.
    private static func structuralPart(_ line: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        var previous: Character? = nil
        for character in line {
            if escaped { escaped = false; previous = character; continue }
            if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                previous = character
                continue
            }
            if character == "\"" { inString = true; previous = character; continue }
            if character == "/" && previous == "/" { out.removeLast(); break }
            out.append(character)
            previous = character
        }
        return out
    }

    /// Where a key may live, or why it may not be written.
    ///
    /// `.missing` and `.inline` are deliberately different answers. Missing
    /// means the section can be created; inline means it exists and must not
    /// be created a second time.
    private enum SectionRange {
        case range(Range<Int>)
        case inline
        case missing
    }

    /// The lines a key may live on: the inside of its section's braces, or the
    /// inside of the root object for a top-level key.
    private static func searchRange(
        _ lines: [String], depths: [Int], section: String?
    ) -> SectionRange {
        guard let section else {
            guard let open = lines.firstIndex(where: { structuralPart($0).contains("{") }),
                  let close = lines.lastIndex(where: { structuralPart($0).contains("}") })
            else { return .missing }
            // `{"scale":1.4}` on one line: nowhere to put a line, and no line to
            // replace.
            guard close > open else { return .inline }
            return .range((open + 1)..<close)
        }
        let opener = try? NSRegularExpression(
            pattern: "^\\s*\"\(NSRegularExpression.escapedPattern(for: section))\"\\s*:\\s*\\{")
        guard let opener else { return .missing }
        for (index, line) in lines.enumerated() where depths[index] == 1 {
            // Matched against the raw line: `structuralPart` throws away string
            // contents, and the section's name is a string.
            guard !isCommented(line) else { continue }
            let span = NSRange(line.startIndex..., in: line)
            guard opener.firstMatch(in: line, range: span) != nil else { continue }
            // A section that opened AND closed on this line — depth is already
            // back to 1 after it — has no inside to write into.
            guard depths[index + 1] > 1 else { return .inline }
            // Its closing brace is the next line that ENDS back at depth 1 —
            // the `},` line itself, not the one after it. Insertions go at the
            // range's end, so being one line out puts a new key outside the
            // section it belongs to.
            guard let close = (index + 1..<lines.count).first(where: { depths[$0 + 1] == 1 })
            else { return .inline }
            return .range((index + 1)..<close)
        }
        return .missing
    }

    /// The lines one setting occupies — one for a scalar, several for a
    /// pretty-printed array, commented or not.
    private static func locate(
        key: String, in lines: [String], range: Range<Int>, depths: [Int], section: String?
    ) -> Range<Int>? {
        let pattern = try? NSRegularExpression(
            pattern: "^\\s*(//\\s*)?\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:")
        guard let pattern else { return nil }
        for index in range {
            // A top-level key is only top-level: the same name nested inside a
            // section is a different setting ("enabled" is in nine of them).
            if section == nil && depths[index] != 1 { continue }
            let line = lines[index]
            let span = NSRange(line.startIndex..., in: line)
            guard pattern.firstMatch(in: line, range: span) != nil else { continue }
            return index..<(index + valueLineCount(lines, from: index))
        }
        return nil
    }

    /// How many lines this setting's value spans. A pretty-printed array opens
    /// a bracket on the key's line and closes it further down; every other
    /// value is one line.
    private static func valueLineCount(_ lines: [String], from index: Int) -> Int {
        var depth = 0
        var count = 0
        for line in lines[index...] {
            count += 1
            for character in structuralPart(uncommented(line)) {
                if character == "{" || character == "[" { depth += 1 }
                if character == "}" || character == "]" { depth -= 1 }
            }
            if depth <= 0 { break }
        }
        return count
    }

    // MARK: - Inserting

    private static func insertSection(
        _ section: String?, key: String, json: String, into lines: [String], depths: [Int]
    ) -> String {
        var lines = lines
        guard let close = lines.lastIndex(where: { structuralPart($0).contains("}") })
        else { return lines.joined(separator: "\n") }
        if let section {
            lines.insert(contentsOf: [
                "  \"\(section)\": {",
                "    \"\(key)\": \(json),",
                "  },",
            ], at: close)
        } else {
            lines.insert("  \"\(key)\": \(json),", at: close)
        }
        return lines.joined(separator: "\n")
    }

    /// What to indent a newly inserted key by: whatever its neighbours use, or
    /// the file's convention if the section is empty.
    private static func insertionIndent(_ lines: [String], range: Range<Int>, section: String?) -> String {
        for index in range where !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            let indent = leadingWhitespace(lines[index])
            if !indent.isEmpty { return indent }
        }
        return section == nil ? "  " : "    "
    }

    // MARK: - Small stuff

    /// One setting written back out as the template writes it: commented, at
    /// the indent of its neighbours, one line per line of a multi-line value.
    private static func commented(_ text: String, indent: String) -> [String] {
        text.components(separatedBy: "\n").enumerated().map { index, line in
            index == 0 ? "\(indent)// \(line)" : "\(indent)// \(line)"
        }
    }

    private static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    private static func isCommented(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// A commented line with its `//` taken off, so a commented value can be
    /// measured the same way an active one is.
    private static func uncommented(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.hasPrefix("//") else { return line }
        return String(trimmed.dropFirst(2))
    }
}
