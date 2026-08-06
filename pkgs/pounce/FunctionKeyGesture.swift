// The pure state machine behind FunctionKeyHotKey's event tap. Kept separate
// from AppKit/CoreGraphics so the ordinary Swift test binary can prove the
// important contract: a lone Fn press-release fires; any intervening keyboard
// event turns it into a chord and suppresses the action.
struct FunctionKeyGesture {
    private(set) var isDown = false
    private var wasChorded = false

    // Returns true exactly when this transition completes a lone Fn tap.
    mutating func functionFlagsChanged(isDown nowDown: Bool) -> Bool {
        if nowDown {
            if !isDown {
                isDown = true
                wasChorded = false
            }
            return false
        }
        guard isDown else { return false }
        let shouldFire = !wasChorded
        reset()
        return shouldFire
    }

    mutating func noteOtherKeyboardEvent() {
        if isDown { wasChorded = true }
    }

    mutating func reset() {
        isDown = false
        wasChorded = false
    }
}
