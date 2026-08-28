import Foundation

// FullscreenGate.decide: the solo-window guard on AeroSpace's fullscreen
// toggle (Windows.swift's Aerospace.fullscreen). Pure string logic, so the
// trap it prevents can be pinned without spawning AeroSpace — and worth
// pinning, because the single-pass version this replaced let the bug through
// invisibly: it only counted siblings listed AFTER the target line, so a
// click on any window that wasn't its workspace's first line silently
// refused to zoom.

func runFullscreenGateTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    let w1 = "7\tw1\tfalse\n9\tw1\tfalse\n12\tw2\tfalse"

    // Siblings count regardless of listing position — the two-pass contract.
    check(FullscreenGate.decide(target: 9, listing: w1) == .zoom,
          "sibling listed before the target still admits the zoom")
    check(FullscreenGate.decide(target: 7, listing: w1) == .zoom,
          "sibling listed after the target admits the zoom")

    // A busy machine isn't a shared workspace: 12 is alone on w2, so it holds
    // even though w1 is two windows deep.
    check(FullscreenGate.decide(target: 12, listing: w1) == .hold,
          "solo window holds even when other workspaces are busy")

    // The OFF take: already fullscreen fires even solo — a window whose
    // siblings all closed must still have a way out of the mode.
    check(FullscreenGate.decide(target: 3, listing: "3\tw1\ttrue") == .zoom,
          "already-fullscreen solo window still toggles OFF")
    check(FullscreenGate.decide(target: 3, listing: "3\tw1\ttrue\n4\tw1\tfalse") == .zoom,
          "already-fullscreen window with siblings toggles OFF")

    // nil — target absent from a well-formed listing: the caller degrades to
    // the ungated toggle (window closed mid-gesture, or unmanaged/floating).
    check(FullscreenGate.decide(target: 99, listing: w1) == nil,
          "target absent from the listing reads as nil")

    // Malformed lines are skipped silently, wherever they sit.
    check(FullscreenGate.decide(target: 3, listing: "garbage\n3\tw1\tfalse\n4\tw1\tfalse") == .zoom,
          "malformed first line is skipped without flipping the verdict")
    check(FullscreenGate.decide(target: 3, listing: "3\tw1\tfalse\ngarbage\n4\tw1\tfalse") == .zoom,
          "malformed mid-listing line is skipped")

    // Whitespace tolerance: don't be brittle to stray spaces around fields.
    check(FullscreenGate.decide(target: 3, listing: "3 \tw1 \tfalse ") == .hold,
          "fields survive stray whitespace")

    if failures == 0 { print("ok — all FullscreenGate tests passed") }
    return failures
}
