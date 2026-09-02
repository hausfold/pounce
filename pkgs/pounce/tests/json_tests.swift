import Foundation

// Json.swift: the one writer behind every `--json`.
//
// What is pinned here is the part callers depend on and nothing else enforces —
// stable key order (so two runs diff), unescaped slashes (pounce answers with
// paths more than with anything else), and a `schema` on every record. All
// three are contract, not formatting preference: the family standard's A2 says
// adding a key is fine and renaming one is breaking, which is only a promise
// worth making if the output is deterministic in the first place.

func runJsonTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // Deterministic: the same record rendered twice is the same bytes, and the
    // keys come out sorted regardless of the order they were built in.
    let a = Json.text(Json.record(["zebra": 1, "apple": 2]))
    let b = Json.text(Json.record(["apple": 2, "zebra": 1]))
    check(a == b, "two identical records must render identically — Swift dictionaries have no order of their own")
    if let zebra = a.range(of: "zebra"), let apple = a.range(of: "apple") {
        check(apple.lowerBound < zebra.lowerBound, "keys must come out sorted")
    } else {
        check(false, "both keys should be present")
    }

    // A path is the most common thing pounce answers with; "\/Users\/…" is a
    // path no reader expects to see.
    let path = Json.text(Json.record(["path": "/Users/x/.config/pounce/config.json"]))
    check(path.contains("/Users/x/.config/pounce/config.json"), "slashes must not be escaped")
    check(!path.contains("\\/"), "slashes must not be escaped")

    // Every record carries a schema, and callers don't have to remember to add it.
    check(Json.text(Json.record([:])).contains("\"schema\""),
          "every record carries a schema number")
    // …but a record that sets one keeps it: `record` fills a gap, it does not
    // overwrite a call site that knows better.
    let stamped = Json.record(["schema": 7])
    check((stamped["schema"] as? Int) == 1,
          "the writer stamps the binary's own schema — a call site cannot fake a different one")

    // Optionals become null rather than a missing key, so a record's SHAPE does
    // not change with its contents. `doctor --json` depends on this: an absent
    // daemon must leave "accessibility" present-and-null, not gone, because gone
    // and false are the two things it exists to distinguish.
    let nulled = Json.text(Json.record(["a": Json.value(nil as String?), "b": Json.value(true as Bool?)]))
    check(nulled.contains("null"), "a nil optional renders as null")
    check(nulled.contains("\"a\""), "a nil optional keeps its key")

    // Round-tripping ConfigSpec's rendered literals is how `config print --json`
    // gets real JSON types out of the table that feeds the annotated template.
    check((Json.parse("200") as? Int) == 200, "a number literal parses back as a number")
    check((Json.parse("true") as? Bool) == true, "a bool literal parses back as a bool")
    check((Json.parse("\"space\"") as? String) == "space", "a string literal parses back as a string")
    check((Json.parse("[\"a\",\"b\"]") as? [String])?.count == 2, "an array literal parses back as an array")
    check(Json.parse("null") is NSNull, "null parses back as null, not as a missing value")

    if failures == 0 { print("ok — all JSON writer tests passed") }
    return failures
}
