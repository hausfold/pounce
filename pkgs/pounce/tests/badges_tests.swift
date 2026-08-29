import Foundation

// BadgeStore and the hint surface: the glyphs formatter, the items `hint` /
// `state` fields, and the first-line/timeout contract of the state runner
// (the cache and in-flight bookkeeping live behind the static store and the
// dispatch queues, so what's testable here is what a fresh instance shows).

func runBadgesTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // MARK: HotKeySpec.glyphs

    check(HotKeySpec.parse("cmd+shift+v")?.glyphs == "⌘⇧V", "chord renders as glyphs")
    check(HotKeySpec.parse("opt+space")?.glyphs == "⌥␣", "space renders as ␣")
    check(HotKeySpec.parse("ctrl+enter")?.glyphs == "⌃↵", "enter renders as ↵")
    check(HotKeySpec.parse("e")?.glyphs == "E", "a bare letter uppercases")
    check(HotKeySpec.parse("fn")?.glyphs == "fn", "fn stays legible rather than tofu")
    check(HotKeySequence.parse("opt+space e")?.glyphs == "⌥␣ E", "a leader sequence spaces its steps")

    // MARK: items.hint — display-only, overrides nothing about how the row runs

    let hinted = ItemSettings.parse([
        "cmd:focus": ["hint": "⇪ f", "state": "echo on"],
        "cmd:plain": ["enabled": true],
        "cmd:empty": ["hint": ""],
    ] as [String: Any])
    check(hinted.entries["cmd:focus"]?.hint == "⇪ f", "hint parses")
    check(hinted.entries["cmd:focus"]?.state == "echo on", "state parses")
    check(hinted.entries["cmd:plain"]?.hint == nil, "an unlisted item has no hint")
    check(hinted.entries["cmd:empty"]?.hint == nil, "an empty hint is treated as none")
    check(hinted.stateCommands.count == 1 && hinted.stateCommands[0].target == "cmd:focus",
          "stateCommands lists exactly the entries that declared one, sorted")

    // MARK: The runner's output contract — first line, trimmed

    // Driven through BadgeStore.fetch's real delivery path (background run →
    // main-queue deliver). The top-level test code owns the main thread, so
    // the poll pumps the run loop rather than blocking it.
    var delivered: String?
    BadgeStore.fetch("echo on") { delivered = $0 }
    check(delivered == nil, "a fetch delivers nothing before its run finishes")

    let deadline = Date().addingTimeInterval(3.0)
    while Date() < deadline && delivered == nil {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    check(delivered == "on", "the delivered value is the command's first stdout line")
    check(BadgeStore.cached(for: "echo on") == "on", "the delivered value is cached")

    // A hanging command yields no badge within the wall-clock cap.
    var hung: String?
    BadgeStore.fetch("sleep 10; echo late") { hung = $0 }
    let hungDeadline = Date().addingTimeInterval(4.0)
    while Date() < hungDeadline && hung == nil {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    check(hung == nil, "a command past the timeout delivers nothing")

    if failures == 0 { print("ok — all badges tests passed") }
    return failures
}
