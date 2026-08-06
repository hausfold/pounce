import Foundation

func runFunctionKeyTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    var tap = FunctionKeyGesture()
    check(!tap.functionFlagsChanged(isDown: true), "Fn down waits for the release")
    check(tap.isDown, "Fn down records an active gesture")
    check(tap.functionFlagsChanged(isDown: false), "a lone Fn release fires")
    check(!tap.isDown, "a completed tap resets")

    var chord = FunctionKeyGesture()
    _ = chord.functionFlagsChanged(isDown: true)
    chord.noteOtherKeyboardEvent()
    check(!chord.functionFlagsChanged(isDown: false), "Fn plus another key does not fire")
    check(!chord.isDown, "a completed chord resets")

    var modifierChord = FunctionKeyGesture()
    _ = modifierChord.functionFlagsChanged(isDown: true)
    modifierChord.noteOtherKeyboardEvent()
    modifierChord.noteOtherKeyboardEvent()
    check(!modifierChord.functionFlagsChanged(isDown: false),
          "multiple events in an Fn chord stay suppressed")

    var noise = FunctionKeyGesture()
    check(!noise.functionFlagsChanged(isDown: false), "a stray Fn-up event does not fire")
    noise.noteOtherKeyboardEvent()
    check(!noise.functionFlagsChanged(isDown: false), "unrelated events cannot prime a tap")

    var repeatedDown = FunctionKeyGesture()
    _ = repeatedDown.functionFlagsChanged(isDown: true)
    check(!repeatedDown.functionFlagsChanged(isDown: true), "a repeated Fn-down does not fire")
    check(repeatedDown.functionFlagsChanged(isDown: false),
          "a repeated Fn-down still completes as one tap")

    if failures == 0 { print("ok — all Fn/Globe gesture tests passed") }
    return failures
}
