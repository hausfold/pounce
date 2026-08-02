// Unit tests for JSONC.swift — the comment/trailing-comma stripper that lets
// `pounce config init`'s annotated config.json be the file pounce actually reads.
//
// Worth covering here rather than by hand because every failure mode is SILENT:
// `Settings.load()` falls back to defaults when parsing fails, so a stripper
// that eats one character too many doesn't crash or warn — the user's settings
// just quietly stop applying. The `//`-inside-a-string case is the one that
// would ship broken and stay unnoticed the longest.
//
// Named with a _tests suffix (see tests/run.sh) so it can't collide with
// JSONC.swift on a case-insensitive filesystem.

import Foundation

func runJSONCTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // Parse through the stripper, the way load() does.
    func parse(_ text: String) -> [String: Any]? {
        let stripped = JSONC.strip(text)
        return try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any]
    }

    // MARK: plain JSON is untouched

    check(JSONC.strip("{\"a\":1}") == "{\"a\":1}",
          "JSON with no comments passes through byte for byte")

    // MARK: line comments

    check(parse("""
    {
      // the answer
      "a": 1
    }
    """)?["a"] as? Int == 1, "a // comment on its own line is removed")

    check(parse("{ \"a\": 1 // trailing note\n }")?["a"] as? Int == 1,
          "a // comment after a value is removed")

    // MARK: the case that would silently eat a setting

    check(parse("{ \"theme\": \"https://example.com/x\" }")?["theme"] as? String
            == "https://example.com/x",
          "// inside a string literal is NOT a comment")

    check(parse("{ \"a\": \"/* not a comment */\" }")?["a"] as? String == "/* not a comment */",
          "/* */ inside a string literal is NOT a comment")

    check(parse(#"{ "a": "say \"//\" here", "b": 2 }"#)?["b"] as? Int == 2,
          "an escaped quote doesn't end the string early")

    check(parse(#"{ "a": "ends with a backslash \\", "b": 2 }"#)?["b"] as? Int == 2,
          "an escaped backslash doesn't swallow the closing quote")

    // MARK: block comments

    check(parse("{ /* off */ \"a\": 1 }")?["a"] as? Int == 1, "a /* */ comment is removed")
    check(parse("{\n/* two\n   lines */\n\"a\": 1 }")?["a"] as? Int == 1,
          "a /* */ comment spanning lines is removed")
    // Unbalanced either way — the point is that the comment text doesn't
    // survive into what JSONSerialization is handed.
    check(JSONC.strip("{ \"a\": 1 /* unterminated") == "{ \"a\": 1 ",
          "an unterminated /* runs to end of input rather than reappearing as garbage")

    // MARK: trailing commas — the other half of "delete what you didn't change"

    check(parse("{ \"a\": 1, }")?["a"] as? Int == 1, "a trailing comma in an object is forgiven")
    check(parse("{ \"a\": [1, 2, ] }")?["a"] as? [Int] ?? [] == [1, 2],
          "a trailing comma in an array is forgiven")
    check(parse("{ \"a\": 1,\n  // a note\n}")?["a"] as? Int == 1,
          "a comment between the last comma and the brace doesn't save the comma")
    check(parse("{ \"a\": { \"b\": 1, }, }")?["a"] as? [String: Any] != nil,
          "trailing commas nest")
    check(parse("{ \"a\": \"x,\" }")?["a"] as? String == "x,",
          "a comma inside a string is not a trailing comma")
    check(parse("{ \"a\": 1, \"b\": 2 }")?["b"] as? Int == 2,
          "a real separating comma survives")

    // MARK: the shape `pounce config init` actually writes

    check(parse("""
    // header
    {
      // How tightly the launcher reads.
      // "windowMode": "compact",

      "clipboard": {
        // How many copies to remember.
        // "maxEntries": 200,
      },
    }
    """)?.isEmpty == false, "an all-commented template parses to just its section objects")

    let template = parse("""
    {
      "clipboard": {
        // "enabled": true,
        "maxEntries": 50,
      },
    }
    """)
    let clipboard = template?["clipboard"] as? [String: Any]
    check(clipboard?["maxEntries"] as? Int == 50,
          "uncommenting one line in a section takes effect")
    check(clipboard?["enabled"] == nil,
          "…and its still-commented sibling stays absent, so the default holds")

    if failures == 0 { print("ok — all JSONC stripper tests passed") }
    return failures
}
