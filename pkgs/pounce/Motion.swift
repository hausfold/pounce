import SwiftUI
import AppKit

// MARK: - Motion

// ONE spring for everything in the palette that moves — the selection glide,
// the dial roll, the action-bar keycap's press blink. The design direction
// states it as a rule rather than a preference ("snappy is a physics constant,
// not a vibe"), which only holds if there is a single place to read it from:
// a second `.spring(response:…)` literal anywhere in the sources is the drift
// this enum exists to prevent.
//
// Deliberately NOT a config setting. The three motions below animate frames
// SwiftUI was already drawing — they cost no keystroke and there is nothing to
// tune — and the one dial a user genuinely has for this is the system's own,
// read below.
enum Motion {
    // The constant PR #111 established, now named once.
    static let response: Double = 0.25
    static let dampingFraction: Double = 0.85

    // nil under System Settings › Accessibility › Display › Reduce motion,
    // which turns every animation here back into exactly today's snap. A nil
    // Animation is not "skip the change": both `withAnimation(nil)` and
    // `.animation(nil, value:)` mean "apply it without one", so the palette
    // stays correct, just instant.
    static var spring: Animation? {
        reduceMotion ? nil : .spring(response: response, dampingFraction: dampingFraction)
    }

    // Read live on every use rather than cached at daemon start: the daemon
    // outlives any number of trips to System Settings, and this is cheap
    // (an AppKit property backed by a cached defaults read).
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // How long a pressed keycap holds its lit state before springing back —
    // long enough to be a blink you can see, short enough to finish inside the
    // 0.4s linger that precedes the window's fade (PounceUI.startLinger).
    static let pressHold: TimeInterval = 0.09
}
