// JSON with comments and trailing commas, reduced to plain JSON.
//
// WHY POUNCE NEEDS THIS. `pounce config init` writes a config.json that carries
// every setting at its default with a comment above it (see ConfigSpec.swift) —
// you learn the surface by reading your own config, and you make it minimal by
// deleting the lines you never touched. JSON has no comments, so the file the
// user reads could not otherwise be the file pounce reads: the alternative was a
// separate reference document to copy out of, which loses the whole point.
//
// Trailing commas come along for the ride because they're the OTHER half of
// "delete what you didn't change": deleting the last entry of an object leaves
// `…, }`, and JSONSerialization rejects that with an error naming a byte offset.
// Being strict there would punish exactly the editing move the file invites.
//
// This is a lexer, not a parser: it decides only whether each character is
// inside a string literal, and deletes comment spans and orphaned commas
// outside them. Everything else — types, keys, structure — is still
// JSONSerialization's job, and a file this mangles into invalid JSON still
// falls back to defaults the same way a malformed one always has.
//
// The case that makes it worth writing carefully rather than with a regex:
// `"theme": "https://example.com/x"` — a `//` INSIDE a string. A naive
// line-wise strip truncates the value and the config silently loses a setting.
// Covered in tests/jsonc_tests.swift.
//
// Foundation-only on purpose (no AppKit), so tests/run.sh can compile it.

import Foundation

enum JSONC {
    /// Strip `//` and `/* */` comments and trailing commas from `text`,
    /// returning plain JSON. Comment characters inside string literals are
    /// left alone.
    ///
    /// Comment spans are replaced by nothing and the surrounding whitespace is
    /// preserved, so byte offsets in a JSONSerialization error still point
    /// somewhere recognisable in the user's own file.
    static func strip(_ text: String) -> String {
        let src = Array(text.unicodeScalars)
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(src.count)

        var inString = false
        var escaped = false
        // Position in `out` of the last comma written, while only whitespace has
        // followed it. That's the one comma a closing brace/bracket can orphan.
        // An Int into a plain array, not a String index — string indices are
        // invalidated by the mutation we're about to do to the very collection
        // they point into.
        var pendingComma: Int?

        var i = 0
        while i < src.count {
            let c = src[i]

            if inString {
                out.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }

            if c == "\"" {
                inString = true
                pendingComma = nil
                out.append(c)
                i += 1
                continue
            }

            // A comment — only out here, where a `/` can't be part of a value.
            if c == "/", i + 1 < src.count {
                if src[i + 1] == "/" {
                    while i < src.count, src[i] != "\n" { i += 1 }
                    continue   // the newline itself is copied on the next pass
                }
                if src[i + 1] == "*" {
                    i += 2
                    while i < src.count {
                        if src[i] == "*", i + 1 < src.count, src[i + 1] == "/" {
                            i += 2
                            break
                        }
                        i += 1
                    }
                    continue
                }
            }

            // A trailing comma is one whose next meaningful character closes the
            // container. Looking ahead would mean skipping comments and
            // whitespace twice, so instead we remember the comma and delete it
            // retroactively when a `}`/`]` turns up with nothing between.
            if c == "," {
                pendingComma = out.count
                out.append(c)
            } else if c == "}" || c == "]" {
                if let comma = pendingComma {
                    out.remove(at: comma)
                    pendingComma = nil
                }
                out.append(c)
            } else {
                if !isWhitespace(c) { pendingComma = nil }
                out.append(c)
            }

            i += 1
        }

        var result = ""
        result.unicodeScalars.append(contentsOf: out)
        return result
    }

    private static func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }
}
