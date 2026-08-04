import Foundation

// Drafts (Drafts.swift): the escape round-trip and the store's invariants.
//
// The escape is the part that matters most — a draft is exactly the text that
// contains newlines, and the store is line-based, so a lossy encode would eat
// the multi-line prompt Shift+Return exists to let you write. The store tests
// run against a real temp HOME rather than a fake filesystem: the paths, the
// atomic write and the cap are the behaviour under test.

func runDraftsTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // ── escaping ────────────────────────────────────────────────────────────
    let roundTrips = [
        "plain text",
        "two\nlines",
        "tab\there",
        "carriage\r\nreturn",
        "a literal backslash \\ and \\n that is NOT a newline",
        "",
        "trailing backslash \\",
        "😀 multibyte\nsurvives",
    ]
    for original in roundTrips {
        let there = Drafts.encode(original)
        check(!there.contains("\n"), "encoded form is one line: \(original.debugDescription)")
        check(Drafts.decode(there) == original,
              "round-trip \(original.debugDescription) -> \(Drafts.decode(there).debugDescription)")
    }

    // The specific confusion the escape exists to prevent: a user who TYPED the
    // two characters backslash-n must not get a newline back.
    check(Drafts.decode(Drafts.encode("\\n")) == "\\n", "typed \\n stays two characters")
    check(Drafts.decode(Drafts.encode("\n")) == "\n", "real newline stays a newline")

    // ── key sanitising (no path escape) ─────────────────────────────────────
    check(!Drafts.path(for: "../../etc/passwd").contains(".."),
          "a traversal key cannot climb out of the drafts dir")
    check(Drafts.sanitize("spawn-agent") == "spawn-agent", "an ordinary key is left alone")
    check(Drafts.sanitize("") == "default", "an empty key still names a file")
    check(Drafts.sanitize("///") == "default", "an all-separator key still names a file")

    // ── store ───────────────────────────────────────────────────────────────
    let home = NSTemporaryDirectory() + "pounce-drafts-tests-\(getpid())"
    setenv("HOME", home, 1)
    defer { try? FileManager.default.removeItem(atPath: home) }

    let key = "unit"
    Drafts.clear(key: key)
    check(Drafts.load(key: key).isEmpty, "an unknown key loads as empty, not an error")

    check(Drafts.save(key: key, text: "  \n\t ", now: 100) == false,
          "an all-whitespace query is not worth keeping")
    check(Drafts.load(key: key).isEmpty, "…and does not create a file")

    check(Drafts.save(key: key, text: "first\nsecond", now: 100), "a real draft saves")
    check(Drafts.save(key: key, text: "first\nsecond", now: 200) == false,
          "re-dismissing the same text does not grow the list")
    check(Drafts.save(key: key, text: "another", now: 300), "different text saves")

    let loaded = Drafts.load(key: key)
    check(loaded.count == 2, "two drafts stored (got \(loaded.count))")
    check(loaded.first?.text == "another", "newest first")
    check(loaded.last?.text == "first\nsecond", "the multi-line draft survives the round trip")
    check(loaded.last?.stamp == 100, "stamps are preserved")

    check(Drafts.remove(key: key, index: 0), "remove by index")
    check(Drafts.load(key: key).map(\.text) == ["first\nsecond"], "the right one was removed")
    check(Drafts.remove(key: key, index: 7) == false, "an out-of-range index is refused")
    check(Drafts.remove(key: key, index: -1) == false, "a negative index is refused")

    // The cap drops the OLDEST, which is the whole point of writing newest-first.
    Drafts.clear(key: key)
    for i in 0..<(Drafts.maxEntries + 5) {
        Drafts.save(key: key, text: "draft \(i)", now: 1000 + i)
    }
    let capped = Drafts.load(key: key)
    check(capped.count == Drafts.maxEntries, "the store is capped (got \(capped.count))")
    check(capped.first?.text == "draft \(Drafts.maxEntries + 4)", "the newest survived")
    check(!capped.contains { $0.text == "draft 0" }, "the oldest was dropped")

    Drafts.clear(key: key)
    check(Drafts.load(key: key).isEmpty, "clear empties the key")

    // ── display helpers ─────────────────────────────────────────────────────
    check(Drafts.preview("one\n\ntwo   three") == "one two three", "preview folds whitespace")
    check(Drafts.preview("   padded   ") == "padded", "preview trims")
    let long = Drafts.preview(String(repeating: "x", count: 200), limit: 10)
    check(long.count == 10 && long.hasSuffix("…"), "preview truncates to the limit with an ellipsis")

    check(Drafts.ago(1000, now: 1010) == "just now", "sub-minute reads as just now")
    check(Drafts.ago(1000, now: 1000 + 300) == "5m ago", "minutes")
    check(Drafts.ago(1000, now: 1000 + 7200) == "2h ago", "hours")
    check(Drafts.ago(1000, now: 1000 + 86400 * 3) == "3d ago", "days")
    check(Drafts.ago(1000, now: 1000 + 86400 * 21) == "3w ago", "weeks")
    check(Drafts.ago(1000, now: 500) == "just now", "a clock that went backwards does not print a negative")

    if failures == 0 { print("ok — all Drafts tests passed") }
    return failures
}
